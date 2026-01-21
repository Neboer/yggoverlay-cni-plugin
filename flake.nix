{
  description = "yggoverlay CNI plugin (for containerd / CNI)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      mkForSystem =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;

          yggoverlay-cni-plugin = pkgs.buildGoModule {
            pname = "yggoverlay-cni-plugin";
            version = if self ? rev then lib.substring 0 8 self.rev else "dirty";

            src = self;

            vendorHash = "sha256-h44omAFdmWFE19ocKWTCIhWKd/J4pV5uPxHg6tqPOAo=";
            ldflags = [
              "-s"
              "-w"
            ];
            subPackages = [ "." ];

            postInstall = ''
              # CNI "type" is "yggoverlay", so ensure the binary name matches.
              if [ -x "$out/bin/yggoverlay" ]; then
                exit 0
              fi

              if [ -x "$out/bin/yggoverlay-cni-plugin" ]; then
                mv "$out/bin/yggoverlay-cni-plugin" "$out/bin/yggoverlay"
                exit 0
              fi

              # Fallback: rename the first produced binary to yggoverlay.
              for b in "$out/bin/"*; do
                if [ -x "$b" ] && [ "$(basename "$b")" != "yggoverlay" ]; then
                  mv "$b" "$out/bin/yggoverlay"
                  break
                fi
              done
            '';
          };
        in
        {
          formatter = nixpkgs.legacyPackages.${system}.nixfmt-tree;

          packages = {
            default = yggoverlay-cni-plugin;
            inherit yggoverlay-cni-plugin;
          };

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              go
              gopls
              golangci-lint
              git
            ];
          };
        };
    in
    flake-utils.lib.eachDefaultSystem mkForSystem
    // {
      overlays.default = final: prev: {
        yggoverlay-cni-plugin = self.packages.${final.system}.yggoverlay-cni-plugin;
      };
      nixosModules.default =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        let
          cfg = config.virtualisation.containerd.extraCNI;
        in
        {
          options.virtualisation.containerd.extraCNI = {
            enable = lib.mkEnableOption "Enable extra CNI settings for containerd";
            enableStandardCNI = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Enable some standard CNI plugins";
            };
            plugins = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [ ];
              example = [ pkgs.yggoverlay-cni-plugin ];
            };
            configFiles = lib.mkOption {
              type = lib.types.attrsOf lib.types.lines;
              default = {};
              example = {
                "30-man8br0.conflist" = ''
                  {
                    "cniVersion": "1.0.0",
                    "name": "man8br",
                    "plugins": [
                      {
                        "type": "bridge",
                        "bridge": "man8br0",
                        "isGateway": true,
                        "ipMasq": true,
                        "ipMasqBackend": "nftables",
                        "ipam": {
                          "type": "host-local",
                          "routes": [
                            {
                              "dst": "0.0.0.0/0"
                            },
                            {
                              "dst": "2000::/3"
                            }
                          ],
                          "ranges": [
                            [
                              {
                                "subnet": "10.4.0.0/24"
                              }
                            ],
                            [
                              {
                                "subnet": "3ffe:ffff:0:01ff::/64",
                                "rangeStart": "3ffe:ffff:0:01ff::0010",
                                "rangeEnd": "3ffe:ffff:0:01ff::ffff"
                              }
                            ]
                          ]
                        }
                      },
                      {
                        "type": "yggoverlay"
                      }
                    ]
                  }
                  	      '';
              };
              description = "Config files of yggoverlay CNI plugin.";
            };
          };

          config =
            let

              cniPlugins = (lib.optionals cfg.enableStandardCNI [ pkgs.cni-plugins ]) ++ cfg.plugins;

              cniBin = pkgs.symlinkJoin {
                name = "cni-plugins-bin";
                paths = map (p: "${p}/bin") cniPlugins;
              };

              conf = pkgs.symlinkJoin {
                name = "cni-plugins-conf";
                paths = lib.mapAttrsToList (
                  fname: contents:
                  pkgs.writeTextFile {
                    name = "${fname}";
                    text = contents;
                    destination = "/${fname}";
                  }
                ) cfg.configFiles;
              };

            in

            lib.mkIf cfg.enable {
              virtualisation.containerd.settings = {
                plugins."io.containerd.grpc.v1.cri".cni = {
                  bin_dir = cniBin;
                  conf_dir = conf;
                };
              };

              nixpkgs.overlays = [ self.overlays.default ];

              environment.systemPackages = [ pkgs.nerdctl ];
            };
        };
    };
}
