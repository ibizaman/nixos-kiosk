{
  pkgs,
  ...
}:
let
  # Generate ed25519 key pairs at build time; the store paths are part of
  # each VM's closure so the files are accessible inside the VM.
  key1 = pkgs.runCommand "ssh-test-key-1" { } ''
    mkdir -p $out
    ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f $out/key -N "" -C "nixos-kiosk-test-1" -q
  '';
  key2 = pkgs.runCommand "ssh-test-key-2" { } ''
    mkdir -p $out
    ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f $out/key -N "" -C "nixos-kiosk-test-2" -q
  '';

  # Settings shared by all four nodes.
  common =
    { ... }:
    {
      users.users.nixos = {
        isNormalUser = true;
        group = "nixos";
      };
      users.groups.nixos = { };

      services.openssh = {
        enable = true;
        settings = {
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
        };
        # Mirror appliance.nix: honour the runtime file written by firstboot.
        authorizedKeysFiles = [
          "%h/.ssh/authorized_keys"
          "/etc/ssh/authorized_keys.d/%u"
          "/var/lib/nixos-kiosk/nixos-authorized-keys"
        ];
      };

      # Place both private keys under /etc so root can use them in the test
      # script.  mode 0400 satisfies ssh's strict permission check.
      environment.etc."test-key-1" = {
        source = "${key1}/key";
        mode = "0400";
      };
      environment.etc."test-key-2" = {
        source = "${key2}/key";
        mode = "0400";
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "app-ssh";

  nodes = {
    # 1. No key — SSH must be rejected.
    no_key = {
      imports = [ common ];
    };

    # 2. Key set via NixOS option (kiosk.sshAuthorizedKeys in production).
    nixos_option = {
      imports = [ common ];
      users.users.nixos.openssh.authorizedKeys.keyFiles = [ "${key1}/key.pub" ];
    };

    # 3. Key set via firstboot kiosk.conf (written to nixos-authorized-keys).
    conf_key = {
      imports = [ common ];
      boot.postBootCommands = ''
        mkdir -p /var/lib/nixos-kiosk
        cp ${key2}/key.pub /var/lib/nixos-kiosk/nixos-authorized-keys
        chmod 644 /var/lib/nixos-kiosk/nixos-authorized-keys
      '';
    };

    # 4. Both sources set — both keys must work independently.
    both_keys = {
      imports = [ common ];
      users.users.nixos.openssh.authorizedKeys.keyFiles = [ "${key1}/key.pub" ];
      boot.postBootCommands = ''
        mkdir -p /var/lib/nixos-kiosk
        cp ${key2}/key.pub /var/lib/nixos-kiosk/nixos-authorized-keys
        chmod 644 /var/lib/nixos-kiosk/nixos-authorized-keys
      '';
    };
  };

  testScript = ''
    no_key.start()
    nixos_option.start()
    conf_key.start()
    both_keys.start()

    no_key.wait_for_unit("sshd.service")
    nixos_option.wait_for_unit("sshd.service")
    conf_key.wait_for_unit("sshd.service")
    both_keys.wait_for_unit("sshd.service")

    ssh_opts = "-o StrictHostKeyChecking=no -o BatchMode=yes -p 22"

    with subtest("no_key: SSH login rejected with no authorized key configured"):
        rc, _ = no_key.execute(
            f"ssh {ssh_opts} -i /etc/test-key-1 nixos@localhost echo ok"
        )
        assert rc != 0, "Expected SSH to fail when no key is authorized"

    with subtest("nixos_option: NixOS option key is accepted"):
        nixos_option.succeed(
            f"ssh {ssh_opts} -i /etc/test-key-1 nixos@localhost echo ok"
        )

    with subtest("nixos_option: conf key is rejected (not installed)"):
        rc, _ = nixos_option.execute(
            f"ssh {ssh_opts} -i /etc/test-key-2 nixos@localhost echo ok"
        )
        assert rc != 0, "Expected conf key to be rejected on nixos_option node"

    with subtest("conf_key: firstboot conf key is accepted"):
        conf_key.succeed(
            f"ssh {ssh_opts} -i /etc/test-key-2 nixos@localhost echo ok"
        )

    with subtest("conf_key: NixOS option key is rejected (not installed)"):
        rc, _ = conf_key.execute(
            f"ssh {ssh_opts} -i /etc/test-key-1 nixos@localhost echo ok"
        )
        assert rc != 0, "Expected NixOS option key to be rejected on conf_key node"

    with subtest("both_keys: NixOS option key works"):
        both_keys.succeed(
            f"ssh {ssh_opts} -i /etc/test-key-1 nixos@localhost echo ok"
        )

    with subtest("both_keys: conf key also works independently"):
        both_keys.succeed(
            f"ssh {ssh_opts} -i /etc/test-key-2 nixos@localhost echo ok"
        )
  '';
}
