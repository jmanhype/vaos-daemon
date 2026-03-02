use std::path::PathBuf;

fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
}

/// OSA Agent TUI CLI arguments
pub struct Cli {
    pub profile: Option<String>,
    pub dev: bool,
    pub setup: bool,
    pub no_color: bool,
    pub version: bool,
}

impl Cli {
    pub fn parse_args() -> Self {
        let mut cli = Self {
            profile: None,
            dev: false,
            setup: false,
            no_color: false,
            version: false,
        };

        let args: Vec<String> = std::env::args().skip(1).collect();
        let mut i = 0;
        while i < args.len() {
            match args[i].as_str() {
                "--profile" => {
                    i += 1;
                    if i < args.len() {
                        cli.profile = Some(args[i].clone());
                    }
                }
                "--dev" => cli.dev = true,
                "--setup" => cli.setup = true,
                "--no-color" => cli.no_color = true,
                "--version" | "-V" => cli.version = true,
                _ => {}
            }
            i += 1;
        }

        if cli.version {
            println!("osagent {}", env!("CARGO_PKG_VERSION"));
            std::process::exit(0);
        }

        cli
    }

    pub fn log_dir(&self) -> PathBuf {
        let base = if let Some(ref profile) = self.profile {
            home_dir().join(".osa").join("profiles").join(profile)
        } else {
            home_dir().join(".osa")
        };
        base.join("logs")
    }
}
