# Important packages of a configuration, evaluated purely against fake configs.
{pkgs}: let
  important = import ../src/important.nix;
  base = {
    environment.systemPackages = [
      {
        pname = "git";
        version = "2.51.0";
      }
    ];
    services = {
      tailscale = {
        enable = true;
        package = {
          pname = "tailscale";
          version = "1.104.5";
        };
      };
      samba = {
        enable = false;
        package = {
          pname = "samba";
          version = "4.25.1";
        };
      };
    };
    programs.fish = {
      enable = true;
      package.name = "fish-4.1.2";
    };
    virtualisation.docker = {
      enable = true;
      package = {
        pname = "docker";
        version = "28.5.1";
      };
    };
    home-manager.users.kuri.home.packages = [
      {
        pname = "ripgrep";
        version = "15.1.0";
      }
    ];
    boot.kernelPackages.kernel = {
      pname = "linux";
      version = "6.18.60";
    };
  };
  all = [
    {
      name = "docker";
      version = "28.5.1";
    }
    {
      name = "fish";
      version = "4.1.2";
    }
    {
      name = "git";
      version = "2.51.0";
    }
    {
      name = "linux";
      version = "6.18.60";
    }
    {
      name = "ripgrep";
      version = "15.1.0";
    }
    {
      name = "tailscale";
      version = "1.104.5";
    }
  ];
  # Compares the JSON of `important { config, options }` with the expected list.
  check = name: config: expected: checkWith name config {} expected;
  checkWith = name: config: options: expected:
    pkgs.runCommand "tabularium-${name}" {
      got = builtins.toJSON (important {inherit config options;});
      want = builtins.toJSON expected;
    } ''
      [ "$got" = "$want" ] || { echo "got:  $got" >&2; echo "want: $want" >&2; exit 1; }
      touch $out
    '';
in {
  important_lists = check "important-lists" base all;

  important_throws = check "important-throws" (base
    // {
      services =
        base.services
        // {
          broken.enable = throw "x";
          badpkg = {
            enable = true;
            package = throw "y";
          };
        };
    })
  all;

  important_no_home_manager =
    check "important-no-home-manager" (removeAttrs base ["home-manager"])
    (builtins.filter (p: p.name != "ripgrep") all);

  # A renamed option aborts when read (`mkRenamedOptionModule`); its option is invisible.
  important_renamed_option = checkWith "important-renamed-option" (base
    // {
      services =
        base.services
        // {
          frp.enable = abort "Renaming error";
        };
    }) {services.frp.enable.visible = false;}
  all;

  # NixOS puts its own base packages in systemPackages; they are not the owner's.
  important_core_excluded = check "important-core-excluded" (base
    // {
      environment = {
        systemPackages =
          base.environment.systemPackages
          ++ [
            {
              pname = "acl";
              version = "2.4.0";
            }
            {
              pname = "nano";
              version = "8.6";
            }
          ];
        corePackages = [
          {
            pname = "acl";
            version = "2.4.0";
          }
        ];
        defaultPackages = [
          {
            pname = "nano";
            version = "8.6";
          }
        ];
      };
    })
  all;
}
