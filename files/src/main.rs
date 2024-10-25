#![warn(clippy::all, clippy::nursery, clippy::cargo, clippy::single_match_else)]
#![allow(clippy::cargo_common_metadata)]

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
    Directories(#[serde(deserialize_with = "expand_path")] Utf8PathBuf),
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

fn main() {
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

fn print_result(result: &NkProvisionStateResult) {
    let json = serde_json::to_string(result)
        .expect("state results to not throw errors serializing...");

    println!("{json}");
}

fn provision(args: Provision) {
    let nk_sources = args.info.sources;

    let states: Vec<State> = match serde_json::from_reader(stdin()) {
        Ok(v) => v,
        Err(e) => {
            // fallback error handler for the deserialize
            print_result(&NkProvisionStateResult {
                status: NkProvisionStateStatus::Failed,
                changed: false,
                description: "files".into(),
                output: format!("{e}: failed deserializing"),
            });

            return;
        }
    };

    for state in states {
        match state {
            State::Files(state) => {
                if let Err(result) = provision_file(&nk_sources, &state) {
                    // fallback error handler for the provision
                    print_result(&NkProvisionStateResult {
                        status: NkProvisionStateStatus::Failed,
                        changed: false,
                        description: display_path_with_tilde(
                            &state.destination,
                        ),
                        output: result.to_string(),
                    });
                }
            }
            State::Directories(destination) => {
                provision_directory(&destination);
            }
        };
    }
}

#[derive(Debug, Serialize, Clone)]
struct NkProvisionStateResult {
    status: NkProvisionStateStatus,
    changed: bool,
    description: String,
    output: String,
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "snake_case")]
enum NkProvisionStateStatus {
    Failed,
    Success,
}

impl NkProvisionStateResult {
    fn append_change<T>(&mut self, change: Result<T, String>) -> Result<T, ()> {
        match change {
            Ok(v) => {
                self.changed = true;

                Ok(v)
            }
            Err(e) => {
                self.status = NkProvisionStateStatus::Failed;
                self.output.push_str(&e);
                self.output.push('\n');

                Err(())
            }
        }
    }

    fn append_check<T>(&mut self, check: Result<T, String>) -> Result<T, ()> {
        match check {
            Ok(v) => Ok(v),
            Err(e) => {
                self.status = NkProvisionStateStatus::Failed;
                self.output.push_str(&e);
                self.output.push('\n');

                Err(())
            }
        }
    }
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
                    display_path_with_tilde(&destination_file)
                ),
                output: String::new(),
            };

            // NOTE: result is exclusively used to make it's implementation
            // cleaner (so we can exit if any change fails), all success/failure
            // details are returned through the mutable result
            let _ = provision_sub_file(
                &mut result,
                &source_file,
                &destination_file,
                *link_files,
            );

            print_result(&result);
        }
    }

    Ok(())
}

fn provision_sub_file(
    result: &mut NkProvisionStateResult,
    source_file: &Utf8Path,
    destination_file: &Utf8Path,
    link_files: bool,
) -> Result<(), ()> {
    // create parent directory
    if let Some(destination_parent) = destination_file.parent() {
        if !destination_parent.exists() {
            // create directory
            result.append_change(
                create_dir_all(destination_parent).map_err(|e| {
                    format!("{e}: failed creating parent directory: {destination_parent}")
                }),
            )?;
        }

        // TODO: should support files.settings or something that we can configure a umask with, then configure that first (assuming it'll apply immediately, if not, use it to calculate perms)
        #[cfg(unix)]
        {
            use std::fs::set_permissions;
            use std::os::unix::prelude::MetadataExt;
            use std::os::unix::prelude::PermissionsExt;

            let metadata =
                destination_parent.metadata().expect("accessing metadata");
            let mut permissions = metadata.permissions();
            let existing_mode = permissions.mode() & 0o777;

            // chmod parent directory
            // TODO: uid != 0 is to ensure we don't try to chmod /Users or other system folders... (might be a better way of handling this...)
            if existing_mode != 0o700 && metadata.uid() != 0 {
                permissions.set_mode(0o700);
                result.append_change(
                    set_permissions(destination_parent, permissions).map_err(
                        |e| {
                            format!(
                                "{e}: failed changing permissions of parent: {destination_parent}",
                            )
                        },
                    ),
                )?;
            }
        }

        #[cfg(windows)]
        {
            use std::os::windows::prelude::*;
            use windows::Win32::Storage::FileSystem::{
                SetFileAttributesW, FILE_ATTRIBUTE_HIDDEN,
            };

            // hide dotfiles on windows
            let file_name = destination_parent.file_name().unwrap_or_default();
            if file_name.starts_with('.') {
                let metadata =
                    destination_parent.metadata().expect("accessing metadata");
                let attributes = metadata.file_attributes();

                // if not hidden
                if (attributes & FILE_ATTRIBUTE_HIDDEN.0) == 0 {
                    // hide
                    result.append_change(
                        unsafe {
                            SetFileAttributesW(
                                &destination_parent.as_os_str().into(),
                                FILE_ATTRIBUTE_HIDDEN,
                            )
                        }
                        .map_err(|e| {
                            format!(
                                "{e}: failed changing attributes of parent: {destination_parent}",
                            )
                        }),
                    )?;
                }
            }
        }
    }

    // create/link

    if source_file.is_dir() {
        // create directory
        provision_directory_impl(result, destination_file)?;
    } else if link_files {
        // link file

        let is_linked_to = result.append_check(
            is_linked_to(destination_file, source_file).map_err(|e| {
                format!("{e}: failed checking link: {destination_file}")
            }),
        )?;

        if !is_linked_to {
            // delete existing first
            if destination_file.is_dir() {
                result.append_change(remove_dir_all(destination_file).map_err(|e| format!(
                    "{e}: failed deleting existing directory: {destination_file}",
                )))?;
            } else if destination_file.is_symlink() || destination_file.exists()
            {
                result.append_change(remove_file(destination_file).map_err(
                    |e| {
                        format!(
                            "{e}: failed deleting existing file: {destination_file}",
                        )
                    },
                ))?;
            }

            // link file
            result.append_change(
                symlink_file(source_file, destination_file).map_err(|e| {
                    format!("{e}: failed linking file: {destination_file}")
                }),
            )?;
        }
    } else {
        // create file
        let file_matches = result.append_check(
            file_contents_match(source_file, destination_file).map_err(|e| {
                format!("{e}: failed linking file: {destination_file}")
            }),
        )?;

        if !file_matches {
            // delete existing first
            if destination_file.is_dir() {
                result.append_change(
                    remove_dir_all(destination_file).map_err(|e| {
                        format!(
                            "{e}: failed deleting existing directory: {destination_file}",
                        )
                    }),
                )?;
            } else if destination_file.is_symlink() {
                result.append_change(remove_file(destination_file).map_err(
                    |e| {
                        format!(
                            "{e}: failed deleting existing symlink: {destination_file}",
                        )
                    },
                ))?;
            }

            // copy file
            result.append_change(
                copy(source_file, destination_file).map_err(|e| {
                    format!("{e}: failed copying file: {destination_file}")
                }),
            )?;
        }

        // TODO: should support files.settings or something that we can configure a umask with, then configure that first (assuming it'll apply immediately, if not, use it to calculate perms)
        #[cfg(unix)]
        {
            use std::fs::set_permissions;
            use std::os::unix::prelude::PermissionsExt;

            let metadata =
                destination_file.metadata().expect("accessing metadata");
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
                result.append_change(
                    set_permissions(destination_file, permissions).map_err(
                        |e| {
                            format!(
                                "{e}: failed changing permissions of file: {destination_file}",
                            )
                        },
                    ),
                )?;
            }
        }
    }

    #[cfg(windows)]
    {
        use std::os::windows::prelude::*;
        use windows::Win32::Storage::FileSystem::{
            SetFileAttributesW, FILE_ATTRIBUTE_HIDDEN,
        };

        // hide dotfiles on windows
        let file_name = destination_file.file_name().unwrap_or_default();
        if file_name.starts_with('.') {
            let metadata =
                destination_file.metadata().expect("accessing metadata");
            let attributes = metadata.file_attributes();

            // if not hidden
            if (attributes & FILE_ATTRIBUTE_HIDDEN.0) == 0 {
                // hide
                result.append_change(
                    unsafe {
                        SetFileAttributesW(
                            &destination_file.as_os_str().into(),
                            FILE_ATTRIBUTE_HIDDEN,
                        )
                    }
                    .map_err(|e| {
                        format!(
                            "{e}: failed changing attributes of directory: {destination_file}",
                        )
                    }),
                )?;
            }
        }
    }

    Ok(())
}

fn provision_directory(destination: &Utf8Path) {
    let mut result = NkProvisionStateResult {
        status: NkProvisionStateStatus::Success,
        changed: false,
        description: format!("create {}", display_path_with_tilde(destination)),
        output: String::new(),
    };

    // NOTE: result is exclusively used to make it's implementation
    // cleaner (so we can exit if any change fails), all success/failure
    // details are returned through the mutable result
    let _ = provision_directory_impl(&mut result, destination);

    print_result(&result);
}

// TODO: rename...
fn provision_directory_impl(
    result: &mut NkProvisionStateResult,
    destination: &Utf8Path,
) -> Result<(), ()> {
    if !destination.is_dir() {
        // delete existing first
        if destination.exists() {
            result.append_change(remove_file(destination).map_err(|e| {
                format!("{e}: failed deleting existing file: {destination}")
            }))?;
        }

        // create directory
        result.append_change(create_dir_all(destination).map_err(|e| {
            format!("{e}: failed creating directory: {destination}")
        }))?;
    }

    // TODO: should support files.settings or something that we can configure a umask with, then configure that first (assuming it'll apply immediately, if not, use it to calculate perms)
    #[cfg(unix)]
    {
        use std::fs::set_permissions;
        use std::os::unix::prelude::PermissionsExt;

        let metadata = destination.metadata().expect("accessing metadata");
        let mut permissions = metadata.permissions();
        let existing_mode = permissions.mode() & 0o777;

        // chmod directory
        if existing_mode != 0o700 {
            permissions.set_mode(0o700);
            result.append_change(
                set_permissions(destination, permissions).map_err(
                    |e| {
                        format!(
                            "{e}: failed changing permissions of directory: {destination}",
                        )
                    },
                ),
            )?;
        }
    }

    Ok(())
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
