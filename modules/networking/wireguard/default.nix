{ config, lib, pkgs, ... }:

let

  cfg = config.networking.wireguard;


  # wg-quick exports a path to a file whose contents reveal "real"
  # interface name. We need this in order to set properties on the
  # (real) interface.
  wgSet = pkgs.writeShellScriptBin "wg-set" ''
    real_ifname=`cat "$WG_TUN_NAME_FILE"`
    ${pkgs.wireguard}/bin/wg set $real_ifname $*
  '';
  
  
  ## Note: we don't inline private keys or PSKs in the config file; we
  ## use PostUp scripts to set them from user-provided files.

  generatePeer = peer:
  let
    allowedIPList = lib.concatStringsSep ", " peer.allowedIPs;
    allowedIPs = lib.optionalString (peer.allowedIPs != []) "AllowedIPs = ${allowedIPList}";
    endpoint = lib.optionalString (peer.endpoint != null) "Endpoint = ${peer.endpoint}";
    keepAlive = lib.optionalString (peer.persistentKeepalive != null) "PersistentKeepalive = ${toString peer.persistentKeepalive}";
    setPSK = lib.optionalString (peer.presharedKeyFile != null) ''
      [Interface]
      PostUp = ${wgSet}/bin/wg-set peer "${peer.publicKey}" preshared-key ${peer.presharedKeyFile}
    '';
  in
  ''
    [Peer]
    PublicKey = ${peer.publicKey}
    ${allowedIPs}
    ${endpoint}
    ${keepAlive}

    ${setPSK}
  '';

  generateInterfaceConfig = interface:
  let
    listenPort = lib.optionalString (interface.listenPort != null) "ListenPort = ${interface.listenPort}";
    addressList = lib.concatStringsSep ", " interface.address;
    address = lib.optionalString (interface.address != []) "Address = ${addressList}";
    mtu = lib.optionalString (interface.mtu != null) "MTU = ${toString interface.mtu}";
    dnsList = lib.concatStringsSep ", " interface.dns;
    dns = lib.optionalString (interface.dns != []) "DNS = ${dnsList}";
    peers = lib.concatStringsSep "\n" (lib.mapAttrsToList (_: peer: generatePeer peer) interface.peers);
    preUpScript = pkgs.writeShellScriptBin "wireguard-${interface.name}-preup" interface.preUp;
    preUp = lib.optionalString (interface.preUp != null) "PreUp = ${preUpScript}/bin/wireguard-${interface.name}-preup";
    postUpScript = pkgs.writeShellScriptBin "wireguard-${interface.name}-postup" interface.postUp;
    postUp = lib.optionalString (interface.postUp != null) "PostUp = ${postUpScript}/bin/wireguard-${interface.name}-postup";
    preDownScript = pkgs.writeShellScriptBin "wireguard-${interface.name}-predown" interface.preDown;
    preDown = lib.optionalString (interface.preDown != null) "PreDown = ${preDownScript}/bin/wireguard-${interface.name}-predown";
    postDownScript = pkgs.writeShellScriptBin "wireguard-${interface.name}-postdown" interface.postDown;
    postDown = lib.optionalString (interface.postDown != null) "PostDown = ${postDownScript}/bin/wireguard-${interface.name}-postdown";
  in
  ''
    [Interface]
    Table = ${interface.table}
    ${listenPort}
    ${address}
    ${mtu}
    ${dns}
    ${preUp}
    PostUp = ${wgSet}/bin/wg-set private-key ${interface.privateKeyFile}
    ${postUp}
    ${preDown}
    ${postDown}

    ${peers}
  '';

  mkConfigFile = name: interface:
  let
    interfaceConfig = generateInterfaceConfig interface;
  in pkgs.writeTextDir name
  ''
    ${interfaceConfig}
  '';

  generateDaemon = name: interface:
  let
    configFileName = "${name}.conf";
    configDir = mkConfigFile configFileName interface;
    configFile = "${configDir}/${configFileName}";
  in
    lib.nameValuePair "wireguard-${name}" {
      script = ''
        _down() { 
          echo "Stopping WireGuard interface ${name}" 
          ${pkgs.wireguard-tools}/bin/wg-quick down ${configFile}
        }

        trap _down SIGTERM

        echo "Starting WireGuard interface ${name}";
        ${pkgs.wireguard-tools}/bin/wg-quick up ${configFile}

        # Wait around for launchd to stop the service via SIGTERM.
        while true; do sleep 60 ; done
      '';

      serviceConfig.ProcessType = "Interactive";
      serviceConfig.StandardErrorPath = interface.logFile;
      serviceConfig.StandardOutPath = interface.logFile;
      serviceConfig.KeepAlive = interface.autoStart;
      serviceConfig.RunAtLoad = interface.autoStart;
    };


  # Create some convenience scripts for starting/stopping the launchd
  # services.
  startScript = name:
  let
    daemonName = config.launchd.daemons."wireguard-${name}".serviceConfig.Label;
  in pkgs.writeShellScriptBin "wg-start-${name}" ''
    launchctl start ${daemonName}
  '';
  stopScript = name:
  let
    daemonName = config.launchd.daemons."wireguard-${name}".serviceConfig.Label;
  in pkgs.writeShellScriptBin "wg-stop-${name}" ''
    launchctl stop ${daemonName}
  '';
  convenienceScripts = pkgs.symlinkJoin {
    name = "wireguard-convenience-scripts";
    paths = (lib.mapAttrsToList (_: config: startScript config.name) cfg.interfaces) ++
            (lib.mapAttrsToList (_: config: stopScript config.name) cfg.interfaces);
  };

in
{
  options.networking.wireguard = {
    interfaces = lib.mkOption {
      type = lib.types.attrsOf pkgs.lib.types.wireguard.interface;
      description = "WireGuard interfaces.";
      default = {};
      example = {
        wg0 = {
          address = [ "192.168.20.4/24" ];
          privateKeyFile = "/path/to/private.key";
          peers.demo =
            { allowedIPs = [ "192.168.20.1/32" ];
              presharedKeyFile = "/path/to/psk.key";
              publicKey  = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=";
              endpoint   = "demo.wireguard.io:12913"; };
        };
      };
    };
  };

  config = lib.mkIf (cfg.interfaces != {}) {
    environment.systemPackages = [
      pkgs.wireguard-tools
      convenienceScripts
    ];

    launchd.daemons = (lib.mapAttrs' generateDaemon cfg.interfaces);
  };
}
