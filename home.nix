{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.nix-neovim-config.localUpdater;
  treesitterWithAllGrammars = pkgs.callPackage ./nix/treesitter-with-all-grammars.nix { };
  stateDirectory = "${config.home.homeDirectory}/.local/state/nix-neovim-config-local-update";
  recoveryPrompt = ./scripts/local-update-recovery.md;
  sshWrapper = pkgs.writeShellApplication {
    name = "nix-neovim-config-local-update-ssh";
    text = ''
      exec ${lib.getExe pkgs.openssh} \
        -F ${lib.escapeShellArg cfg.ssh.configFile} \
        -o BatchMode=yes \
        "$@"
    '';
  };
  updater = pkgs.writeShellApplication {
    name = "nix-neovim-config-local-update";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      pkgs.nix
      pkgs.openssh
      cfg.package
      pkgs.util-linux
    ];
    text = builtins.readFile ./scripts/local-update.sh;
  };
in
{
  options.programs.nix-neovim-config.localUpdater = {
    enable = lib.mkEnableOption "daily checked flake updates with one-shot Pi recovery";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.pi-coding-agent;
      description = "Pi package used only for bounded recovery after deterministic update failure.";
    };

    ssh.configFile = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "/.*");
      default = null;
      example = "/home/user/.ssh/config";
      description = "Absolute runtime SSH config path used by Git; contents stay outside the Nix store.";
    };
  };

  config = {
    xdg.configFile."nvim" = {
      source = ./nvim;
      recursive = true;
    };

    xdg.dataFile."nvim/nix/nvim-treesitter".source = treesitterWithAllGrammars;

    home.activation.nixNeovimConfigLocalUpdaterState = lib.mkIf cfg.enable (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${pkgs.coreutils}/bin/install -d -m 0700 -- ${lib.escapeShellArg stateDirectory}
      ''
    );

    systemd.user.services.nix-neovim-config-local-update = lib.mkIf cfg.enable {
      Unit = {
        Description = "Update nix-neovim-config with checked flake inputs and bounded Pi recovery";
        Wants = [ "network-online.target" ];
        After = [ "network-online.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = lib.getExe updater;
        Environment = [
          "LOCAL_UPDATE_RECOVERY_PROMPT=${recoveryPrompt}"
          "LOCAL_UPDATE_STATE_DIR=${stateDirectory}"
          "XDG_CACHE_HOME=${stateDirectory}/cache"
          "PI_OFFLINE=1"
          "PI_TELEMETRY=0"
        ]
        ++ lib.optional (cfg.ssh.configFile != null) "GIT_SSH_COMMAND=${lib.getExe sshWrapper}";
        TimeoutStartSec = "6h";
        UMask = "0077";
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadWritePaths = [
          stateDirectory
          "-${config.home.homeDirectory}/.pi"
        ];
        PrivateTmp = true;
        NoNewPrivileges = true;
        LockPersonality = true;
        RestrictSUIDSGID = true;
      };
    };

    systemd.user.timers.nix-neovim-config-local-update = lib.mkIf cfg.enable {
      Unit.Description = "Daily nix-neovim-config update";
      Timer = {
        OnCalendar = "*-*-* 04:00:00";
        Persistent = true;
        Unit = "nix-neovim-config-local-update.service";
      };
      Install.WantedBy = [ "timers.target" ];
    };

    # ponytail: fixed repository and 04:00 schedule; make configurable when a second deployment exists.
    home.packages = with pkgs; [
      astro-language-server
      biome
      cargo
      delve
      docker-compose-language-service
      dockerfile-language-server
      fd
      gcc
      git
      go
      gofumpt
      golangci-lint
      gomodifytags
      gopls
      gotools
      hadolint
      impl
      lazygit
      lsof
      lua-language-server
      markdown-toc
      markdownlint-cli2
      nil
      nixfmt
      nodejs
      prettier
      ripgrep
      shfmt
      sops
      sqlfluff
      statix
      stylua
      svelte-language-server
      tailwindcss-language-server
      taplo
      tree-sitter
      typescript
      unzip
      vscode-langservers-extracted
      yaml-language-server
    ];
  };
}
