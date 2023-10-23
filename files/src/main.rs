#![warn(clippy::all, clippy::pedantic, clippy::nursery, clippy::cargo)]
#![allow(clippy::cargo_common_metadata)]
#![allow(clippy::too_many_lines)]

mod args;

use anyhow::{anyhow, Result};
use args::{Arguments, Commands, Provision};
use camino::{Utf8Path, Utf8PathBuf};
use clap::Parser;
use faccess::PathExt;
use file_id::get_file_id;
use serde::{de::Error, Deserialize, Deserializer, Serialize};
use std::{
    fs::{copy, create_dir_all, remove_dir_all, remove_file, File},
    io::{stdin, Read},
    path::Path,
    str::FromStr,
};
use walkdir::WalkDir;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case", tag = "declaration", content = "state")]
enum State {
    Files(FileState),
}

#[derive(Debug, Deserialize)]
struct FileState {
    source: Utf8PathBuf,
    #[serde(deserialize_with = "expand_path")]
    destination: Utf8PathBuf,
    #[serde(default)]
    link_files: bool,
}

fn expand_path<'de, D>(deserializer: D) -> Result<Utf8PathBuf, D::Error>
where
    D: Deserializer<'de>,
{
    let path: String = Deserialize::deserialize(deserializer)?;
    // TODO: maybe std::path::absolute once stable?
    Utf8PathBuf::from_str(&shellexpand::tilde(&path)).map_err(D::Error::custom)
}

fn main() -> Result<()> {
    let args = Arguments::parse();

    match args.command {
        Commands::Provision(args) => provision(args),
    }
}

fn display_path_with_tilde(path: &Utf8Path) -> String {
    let mut path_string = path.to_string();

    if let Some(home_dir) = dirs::home_dir() {
        if let Ok(home) = Utf8PathBuf::try_from(home_dir) {
            let home_str = home.as_str();
            if path_string.starts_with(home_str) {
                path_string.replace_range(0..home_str.len(), "~");
            }
        }
    }

    path_string
}

fn provision(args: Provision) -> Result<()> {
    let nk_sources = args.info.sources;

    let states: Vec<State> = serde_json::from_reader(stdin())?;

    for state in states {
        match state {
            State::Files(state) => {
                if let Err(result) = provision_file(&nk_sources, &state) {
                    // fallback error handler for the provision
                    println!(
                        "{}",
                        serde_json::to_string(&NkProvisionStateResult {
                            status: NkProvisionStateStatus::Failed,
                            changed: false,
                            description: display_path_with_tilde(
                                &state.destination
                            ),
                            output: result.to_string()
                        })?
                    );
                }
            }
        };
    }

    Ok(())
}

#[derive(Debug, Serialize)]
struct NkProvisionStateResult {
    status: NkProvisionStateStatus,
    changed: bool,
    description: String,
    output: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "snake_case")]
enum NkProvisionStateStatus {
    Failed,
    Success,
}

fn provision_file(nk_sources: &[Utf8PathBuf], state: &FileState) -> Result<()> {
    let FileState {
        source,
        destination,
        link_files,
    } = state;
    // find sources
    let nk_source_relative_sources = nk_sources
        .iter()
        .map(|nk_source| nk_source.join(source))
        .filter(|p| p.exists())
        .collect::<Vec<_>>();

    // need at least one source to proceed
    if nk_source_relative_sources.is_empty() {
        return Err(anyhow!("{source}: does not exist"));
    }

    // check if any sources aren't listable
    let nk_source_relative_sources = nk_source_relative_sources
        .iter()
        .map(|p| {
            if p.is_dir() && !p.as_std_path().executable() {
                return Err(anyhow!("{p}: is not listable"));
            }

            Ok(p)
        })
        .collect::<Result<Vec<_>>>()?;

    // walk each source
    for nk_source_relative_source in nk_source_relative_sources {
        for entry in WalkDir::new(nk_source_relative_source).sort_by_file_name()
        {
            let entry = entry?;
            let source_file =
                Utf8PathBuf::from_path_buf(entry.path().into()).unwrap();

            // figure out destination file path
            let destination_file = if source_file == *nk_source_relative_source
            {
                // root of the source
                destination.clone()
            } else {
                // child of the source
                destination
                    .join(source_file.strip_prefix(nk_source_relative_source)?)
            };

            let output = provision_sub_file(
                &source_file,
                &destination_file,
                *link_files,
            );

            println!("{}", serde_json::to_string(&output)?);
        }
    }

    Ok(())
}

fn provision_sub_file(
    source_file: &Utf8Path,
    destination_file: &Utf8Path,
    link_files: bool,
) -> NkProvisionStateResult {
    let action = if !link_files || source_file.is_dir() {
        "create"
    } else {
        "link"
    };

    let mut result = NkProvisionStateResult {
        status: NkProvisionStateStatus::Success,
        changed: false,
        description: format!(
            "{action} {}",
            display_path_with_tilde(destination_file)
        ),
        output: String::new(),
    };

    // create parent directory
    if let Some(destination_parent) = destination_file.parent() {
        if !destination_parent.exists() {
            // create directory
            if let Err(e) = create_dir_all(destination_parent) {
                // failed creating parent directory
                result.status = NkProvisionStateStatus::Failed;
                result.output = format!(
                    "{e}: failed creating parent directory: {destination_parent}",
                );

                return result;
            };
            result.changed = true;
        }

        // TODO: should support files.settings or something that we can configure a umask with, then configure that first (assuming it'll apply immediately, if not, use it to calculate perms)
        #[cfg(unix)]
        {
            use std::fs::set_permissions;
            use std::os::unix::prelude::MetadataExt;
            use std::os::unix::prelude::PermissionsExt;

            // TODO: fix unwrap
            let metadata = destination_parent.metadata().unwrap();
            let mut permissions = metadata.permissions();
            let existing_mode = permissions.mode() & 0o777;

            // chmod parent directory
            // TODO: uid != 0 is to ensure we don't try to chmod /Users or other system folders... (might be a better way of handling this...)
            if existing_mode != 0o700 && metadata.uid() != 0 {
                permissions.set_mode(0o700);
                if let Err(e) = set_permissions(destination_parent, permissions)
                {
                    // failed changing permissions of parent
                    result.status = NkProvisionStateStatus::Failed;
                    result.output = format!(
                        "{e}: failed changing permissions of parent: {destination_parent}",
                    );

                    return result;
                };
                result.changed = true;
            }
        }
    }

    // create/link

    if source_file.is_dir() {
        // create directory

        if !destination_file.is_dir() {
            // delete existing first
            if destination_file.exists() {
                if let Err(e) = remove_file(destination_file) {
                    // failed deleting existing file
                    result.status = NkProvisionStateStatus::Failed;
                    result.output = format!(
                        "{e}: failed deleting existing file: {destination_file}",
                    );

                    return result;
                };
                result.changed = true;
            }

            // create directory
            if let Err(e) = create_dir_all(destination_file) {
                // failed creating directory
                result.status = NkProvisionStateStatus::Failed;
                result.output = format!(
                    "{e}: failed creating directory: {destination_file}",
                );

                return result;
            };
            result.changed = true;
        }

        // TODO: should support files.settings or something that we can configure a umask with, then configure that first (assuming it'll apply immediately, if not, use it to calculate perms)
        #[cfg(unix)]
        {
            use std::fs::set_permissions;
            use std::os::unix::prelude::PermissionsExt;

            // TODO: fix unwrap
            let metadata = destination_file.metadata().unwrap();
            let mut permissions = metadata.permissions();
            let existing_mode = permissions.mode() & 0o777;

            // chmod directory
            if existing_mode != 0o700 {
                permissions.set_mode(0o700);
                if let Err(e) = set_permissions(destination_file, permissions) {
                    // failed changing permissions of parent
                    result.status = NkProvisionStateStatus::Failed;
                    result.output = format!(
                        "{e}: failed changing permissions of directory: {destination_file}",
                    );

                    return result;
                };
                result.changed = true;
            }
        }
    } else if link_files {
        // link file

        let is_linked_to = match is_linked_to(destination_file, source_file) {
            Ok(v) => v,
            Err(e) => {
                // failed linking file
                result.status = NkProvisionStateStatus::Failed;
                result.output =
                    format!("{e}: failed checking link: {destination_file}");

                return result;
            }
        };

        if !is_linked_to {
            // delete existing first
            if destination_file.is_dir() {
                if let Err(e) = remove_dir_all(destination_file) {
                    // failed deleting existing directory
                    result.status = NkProvisionStateStatus::Failed;
                    result.output = format!(
                        "{e}: failed deleting existing directory: {destination_file}",
                    );

                    return result;
                };
                result.changed = true;
            } else if destination_file.is_symlink() || destination_file.exists()
            {
                if let Err(e) = remove_file(destination_file) {
                    // failed deleting existing file
                    result.status = NkProvisionStateStatus::Failed;
                    result.output = format!(
                        "{e}: failed deleting existing file: {destination_file}",
                    );

                    return result;
                };
                result.changed = true;
            }

            // link file
            if let Err(e) = symlink_file(source_file, destination_file) {
                // failed linking file
                result.status = NkProvisionStateStatus::Failed;
                result.output =
                    format!("{e}: failed linking file: {destination_file}");

                return result;
            };
            result.changed = true;
        }
    } else {
        // create file

        let file_matches =
            match file_contents_match(source_file, destination_file) {
                Ok(v) => v,
                Err(e) => {
                    // failed linking file
                    result.status = NkProvisionStateStatus::Failed;
                    result.output = format!(
                        "{e}: failed linking file: {destination_file}",
                    );

                    return result;
                }
            };
        if !file_matches {
            // delete existing first
            if destination_file.is_dir() {
                if let Err(e) = remove_dir_all(destination_file) {
                    // failed deleting existing directory
                    result.status = NkProvisionStateStatus::Failed;
                    result.output = format!(
                        "{e}: failed deleting existing directory: {destination_file}",
                    );

                    return result;
                };
                result.changed = true;
            } else if destination_file.is_symlink() {
                if let Err(e) = remove_file(destination_file) {
                    // failed deleting existing symlink
                    result.status = NkProvisionStateStatus::Failed;
                    result.output = format!(
                        "{e}: failed deleting existing symlink: {destination_file}",
                    );

                    return result;
                };
                result.changed = true;
            }

            // copy file
            if let Err(e) = copy(source_file, destination_file) {
                // failed copying file
                result.status = NkProvisionStateStatus::Failed;
                result.output =
                    format!("{e}: failed copying file: {destination_file}");

                return result;
            };
            result.changed = true;
        }

        // TODO: should support files.settings or something that we can configure a umask with, then configure that first (assuming it'll apply immediately, if not, use it to calculate perms)
        #[cfg(unix)]
        {
            use std::fs::set_permissions;
            use std::os::unix::prelude::PermissionsExt;

            // TODO: fix unwrap
            let metadata = destination_file.metadata().unwrap();
            let mut permissions = metadata.permissions();
            let existing_mode = permissions.mode() & 0o777;

            // determine perms to set
            let perms = if source_file.as_std_path().executable() {
                0o700
            } else {
                0o600
            };

            // chmod file
            if existing_mode != perms {
                permissions.set_mode(perms);
                if let Err(e) = set_permissions(destination_file, permissions) {
                    // failed changing permissions of parent
                    result.status = NkProvisionStateStatus::Failed;
                    result.output = format!(
                        "{e}: failed changing permissions of file: {destination_file}",
                    );

                    return result;
                };
                result.changed = true;
            }
        }
    }

    result
}

fn is_linked_to(
    destination_file: &Utf8Path,
    source_file: &Utf8Path,
) -> std::io::Result<bool> {
    // if destination doesn't exist (ie. broken link), it's not linked
    if !destination_file.exists() {
        return Ok(false);
    }

    let destination_file_id = get_file_id(destination_file)?;
    let source_file_id = get_file_id(source_file)?;

    Ok(destination_file_id == source_file_id)
}

#[cfg(unix)]
fn symlink_file<P: AsRef<Path>, Q: AsRef<Path>>(
    original: P,
    link: Q,
) -> std::io::Result<()> {
    std::os::unix::fs::symlink(original, link)
}

#[cfg(windows)]
fn symlink_file<P: AsRef<Path>, Q: AsRef<Path>>(
    original: P,
    link: Q,
) -> std::io::Result<()> {
    std::os::windows::fs::symlink_file(original, link)
}

fn file_contents_match(
    source: &Utf8Path,
    destination: &Utf8Path,
) -> std::io::Result<bool> {
    if !destination.exists() || destination.is_dir() {
        return Ok(false);
    }

    let mut source_file = File::open(source)?;
    let mut destination_file = File::open(destination)?;

    // check file size
    if source_file.metadata()?.len() != destination_file.metadata()?.len() {
        return Ok(false);
    }

    // check file contents
    let mut source_contents = String::new();
    let mut destination_contents = String::new();

    source_file.read_to_string(&mut source_contents)?;
    destination_file.read_to_string(&mut destination_contents)?;

    if source_contents != destination_contents {
        return Ok(false);
    }

    // TODO: allow this to handle large files (maybe have a size limit where it still does the simple thing of loading the whole thing? since that's likely fairly fast...)
    // // check file contents
    // let mut source_buf_reader = BufReader::new(source_file);
    // let mut destination_buf_reader = BufReader::new(destination_file);

    // const SIZE: usize = 8192;
    // let mut source_buffer = [0u8; SIZE];
    // let mut destination_buffer = [0u8; SIZE];

    // source_buf_reader.read_exact(&mut source_buffer)?;
    // destination_buf_reader.read_exact(&mut destination_buffer)?;

    Ok(true)
}
