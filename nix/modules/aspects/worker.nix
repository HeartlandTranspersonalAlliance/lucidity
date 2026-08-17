{...}: {
  den.aspects.worker.bootc = {
    lucidity = {
      role = "worker";
      hostName = "worker";
      overlayIPv4 = "100.96.0.2";
      nebulaGroups = [
        "server"
        "worker"
      ];
      persistentPaths = [
        "/data/coolify"
        "/var/lib/coolify"
      ];
      files."etc/coolify-worker/README" = ''
        The controller's SSH public key is enrolled at runtime through SSM.
        The matching private key never leaves the controller.
      '';
    };
  };
}
