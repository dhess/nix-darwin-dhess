{ config, lib, pkgs, ... }:

let

  cfg = config.networking.wireguard;

  controlPerms = if cfg.rootOnly then "0755" else "0777";

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
        while [ -f /var/run/wireguard/control/${name}.up ] ; do sleep 1 ; done
        _down
      '';

      serviceConfig.ProcessType = "Interactive";
      serviceConfig.StandardErrorPath = interface.logFile;
      serviceConfig.StandardOutPath = interface.logFile;
      serviceConfig.RunAtLoad = interface.autoStart;

      # Note: PathState doesn't work as it's explained in the
      # launchd.plist man page, which implies that the job will be
      # stopped when the path no longer exists. launchd will *start*
      # the job upon creation of the path, but not the converse.
      # Therefore, in the launchd script, we watch for the path to go
      # away and then bring down the interface ourselves.

      serviceConfig.KeepAlive = if interface.autoStart then true else {
        PathState = { "/var/run/wireguard/control/${name}.up" = true; };
      };
    };

  controlScript = name:
  let
    daemonName = config.launchd.daemons."wireguard-${name}".serviceConfig.Label;
  in pkgs.writeShellScriptBin "wg-${name}" ''
    function usage {
        echo "usage: `basename $0` up|down" >&2
        exit 1
    }
    [[ $# == 1 ]] || usage
    control_file="/var/run/wireguard/control/${name}.up"
    case "$1" in
      up   ) touch $control_file || echo "Can't bring up ${name}; try running as root." && exit 1;;
      down ) rm -f $control_file || echo "Can't bring down ${name}; try running as root." && exit 1;;
      *    ) usage
    esac
  '';

  convenienceScripts = pkgs.symlinkJoin {
    name = "wireguard-convenience-scripts";
    paths = lib.mapAttrsToList (_: config: controlScript config.name) cfg.interfaces;
  };

in
{
  options.networking.wireguard = {
    rootOnly = lib.mkEnableOption ''
      If false (the default), any user can start and stop any
      WireGuard interface. Otherwise, only root can do so.
    '';

    interfaces = lib.mkOption {
      type = lib.types.attrsOf pkgs.lib.types.wireguard.interface;
      description = ''
        Zero or more declarative WireGuard interfaces. The attribute
        name of each interface declaration should be a valid WireGuard
        interface name.

        Unless they are configured to auto-start (see below),
        interfaces defined here are started and stopped using a script
        named <literal>wg-<emphasis>name</emphasis></literal>, where
        <literal><emphasis>name</emphasis></literal> is the attribute
        name for the given interface. Use <literal>wg-name
        up</literal> to bring the interface up, or <literal>wg-name
        down</literal> to bring it down.

        Interfaces configured to auto-start will run automatically,
        i.e., at boot, or as soon as the nix-darwin configuration is
        activated. These can only be deactivated by removing them from
        the nix-darwin configuration and making the new configuration
        active, or by unloading them using launchd directly like so:
        <literal>launchd unload
        org.nixos.wireguard-<emphasis>interface-name</emphasis></literal>.

        Note that WireGuard secrets such as interface private keys and
        pre-shared keys are never stored in the Nix store. As such,
        they must be provided out-of-band, and secured by the user.
      '';
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

    system.activationScripts.postActivation.text = ''
      if [ ! -d /var/run/wireguard ] ; then
        install -d -o root -g daemon -m 0755 /var/run/wireguard
      fi
      install -d -o root -g daemon -m ${controlPerms} /var/run/wireguard/control
    '';
  };
}
