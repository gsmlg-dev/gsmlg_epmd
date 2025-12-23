{ pkgs, lib, config, inputs, ... }:

let
  pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
  pkgs-unstable = import inputs.nixpkgs-unstable { system = pkgs.stdenv.system; };
in
{
  env.GREET = "GSMLG EPMD";

  packages = with pkgs-stable; [
    git
    figlet
    lolcat
    watchman
    rebar3
    openssl
  ] ++ lib.optionals stdenv.isLinux [
    inotify-tools
  ];

  # Enable Erlang support
  languages.erlang.enable = true;
  languages.erlang.package = pkgs-stable.beam27Packages.erlang;

  # Enable Elixir support (for Mix dependencies like mdns)
  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam27Packages.elixir;

  scripts.hello.exec = ''
    figlet -w 120 $GREET | lolcat
  '';

  enterShell = ''
    hello
  '';

}
