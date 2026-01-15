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

          # containerd CRI's CNI config takes ONE bin_dir (a single directory).
          # So we create a merged directory containing both:
          #   - the standard reference plugins (bridge, host-local, ...)
          #   - yggoverlay
          cni-plugins-with-yggoverlay = pkgs.symlinkJoin {
            name = "cni-plugins-with-yggoverlay";
            paths = [
              pkgs.cni-plugins
              yggoverlay-cni-plugin
            ];
          };
        in
        {
          formatter = nixpkgs.legacyPackages.${system}.nixfmt-tree;

          packages = {
            default = yggoverlay-cni-plugin;
            inherit yggoverlay-cni-plugin cni-plugins-with-yggoverlay;
          };

          overlays.default = final: prev: {
            yggoverlay-cni-plugin = self.packages.${system}.yggoverlay-cni-plugin;
            cni-plugins-with-yggoverlay = self.packages.${system}.cni-plugins-with-yggoverlay;
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
      nixosModules.default =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        let
          cfg = config.virtualisation.containerd.yggoverlayCNI;
          bundle = self.packages.${pkgs.system}.cni-plugins-with-yggoverlay;
        in
        {
          options.virtualisation.containerd.yggoverlayCNI = {
            enable = lib.mkEnableOption "Install yggoverlay CNI plugin and point containerd's CNI bin_dir at a merged plugin bundle";
	    
          };

          config = lib.mkIf cfg.enable {
            # containerd CRI plugin CNI paths: bin_dir, conf_dir
            # (bin_dir default is /opt/cni/bin; conf_dir default is /etc/cni/net.d).
            virtualisation.containerd.settings.plugins."io.containerd.grpc.v1.cri".cni = {
              bin_dir = "${bundle}/bin";
              conf_dir = "/etc/cni/net.d";
            };

            environment.systemPackages = [ pkgs.nerdctl ];
          };
        };
    };
}
