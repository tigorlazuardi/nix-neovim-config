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
      pkgs.bubblewrap
      pkgs.coreutils
      pkgs.git
      pkgs.gnutar
      pkgs.jq
      pkgs.neovim
      pkgs.nix
      pkgs.openssh
      pkgs.python3
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

    recoveryModel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "openai-codex/gpt-5.6-sol";
      description = ''
        Provider/model passed as `--model` to the bounded Pi recovery invocation.
        `null` omits the flag so recovery inherits the Pi default provider/model.
      '';
    };
  };

  options.programs.nix-neovim-config.lazyRestore.enable = lib.mkOption {
    description = "Converge the live lazy.nvim plugin tree to the lock at switch time. Opt-in: machines sharing this module (nspawn boxes) must boot fast and never git-clone plugins during activation.";
    type = lib.types.bool;
    default = false;
  };

  config = {
    xdg.configFile."nvim" = {
      source = ./nvim;
      recursive = true;
    };

    xdg.dataFile."nvim/nix/nvim-treesitter".source = treesitterWithAllGrammars;

    # Converge the live lazy.nvim plugin tree to the committed lock when the
    # pinned LazyVim rev differs from the live checkout. Without this, a config
    # referencing a new LazyVim extra (e.g. lang.typescript.tsc) can start nvim
    # against the OLD LazyVim tree and fail with `loadfile(nil)` ("Failed to
    # load lazyvim.plugins.extras..."). Restore needs network and can clone
    # dozens of plugins, so it is OPT-IN (machines sharing this module, like
    # the nspawn boxes, must boot in seconds) and skipped when there is no
    # live LazyVim tree yet (fresh home) - first nvim start installs it anyway.
    home.activation.nixNeovimLazyRestore = lib.mkIf config.programs.nix-neovim-config.lazyRestore.enable (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        lockRev=$(${pkgs.jq}/bin/jq -r '.LazyVim.commit // empty' "${config.home.homeDirectory}/.config/nvim/lazy-lock.json" 2>/dev/null || true)
        liveRev=$(${pkgs.git}/bin/git -C "${config.home.homeDirectory}/.local/share/nvim/lazy/LazyVim" rev-parse HEAD 2>/dev/null || true)
        if [ -n "$lockRev" ] && [ -n "$liveRev" ] && [ "$lockRev" != "$liveRev" ]; then
          if ${pkgs.coreutils}/bin/timeout 300 ${lib.getExe pkgs.neovim} --headless "+Lazy! restore" +qa; then
            echo "nix-neovim-config: lazy.nvim plugins restored to lock"
          else
            echo "nix-neovim-config: Lazy restore failed (offline?) - retry next switch" >&2
          fi
        fi
      ''
    );

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
          "LOCAL_UPDATE_DAILY_RUNNER=${./scripts/daily-update.sh}"
          "LOCAL_UPDATE_RECOVERY_PROMPT=${recoveryPrompt}"
          "LOCAL_UPDATE_STATE_DIR=${stateDirectory}"
          "XDG_CACHE_HOME=${stateDirectory}/cache"
          "PI_OFFLINE=1"
          "PI_TELEMETRY=0"
        ]
        ++ lib.optional (cfg.ssh.configFile != null) "GIT_SSH_COMMAND=${lib.getExe sshWrapper}"
        ++ lib.optional (cfg.recoveryModel != null) "LOCAL_UPDATE_RECOVERY_MODEL=${cfg.recoveryModel}";
        TimeoutStartSec = "6h";
        UMask = "0077";
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadWritePaths = [ stateDirectory ];
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
