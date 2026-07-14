podman run -d \
      --name openshell-standalone \
      --user 0:0 \
      -e OPENSHELL_LOG_LEVEL=debug \
      \
      --cap-add SYS_ADMIN \
      --cap-add NET_ADMIN \
      --cap-add SYS_PTRACE \
      --cap-add SYSLOG \
      --cap-add DAC_READ_SEARCH \
      --cap-add SETPCAP \
      \
      --cap-drop DAC_OVERRIDE \
      --cap-drop FSETID \
      --cap-drop KILL \
      --cap-drop NET_BIND_SERVICE \
      --cap-drop NET_RAW \
      --cap-drop SETFCAP \
      --cap-drop SYS_CHROOT \
      \
      --security-opt no-new-privileges \
      --security-opt seccomp=unconfined \
      \
      -v ./policy.rego:/etc/openshell/policy.rego:ro,z \
      -v ./policy.yaml:/etc/openshell/policy-data.yaml:ro,z \
      \
      localhost/openshell-sandbox:latest \
      --log-level info \
      --policy-rules /etc/openshell/policy.rego \
      --policy-data /etc/openshell/policy-data.yaml \
      curl https://api.github.com
