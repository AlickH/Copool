fn main() {
    if let Err(error) = copool_windows_lib::proxy_daemon::run_cli_from_env() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
