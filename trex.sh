echo "- c: 16
  interfaces:
  - '0000:38:00.0'
  - 0000:3a:00.0
  limit_memory: '8192'
  platform:
    dual_if:
    - socket: 0
      threads:
      - 2
      - 3
      - 4
      - 5
      - 6
      - 7
      - 8
      - 9
      - 10
      - 11
      - 12
      - 13
      - 14
      - 15
      - 16
      - 17
    - socket: 0
      threads:
      - 2
      - 3
      - 4
      - 5
      - 6
      - 7
      - 8
      - 9
      - 10
      - 11
      - 12
      - 13
      - 14
      - 15
      - 16
      - 17
    latency_thread_id: 1
    master_thread_id: 0
  port_info:
  - dest_mac: 40:a6:b7:ca:2a:50
    src_mac: 40:a6:b7:ca:2a:70
  - dest_mac: 40:a6:b7:ca:2a:58
    src_mac: 40:a6:b7:ca:2a:74
  version: 2
" | sudo tee /etc/trex_cfg.yaml


sudo ./t-rex-64 -i --prefix $(hostname) --hdrh --no-scapy-server --mbuf-factor 32


# vpp# set ip neighbor avf-0/38/1/0 192.168.1.1 40:a6:b7:ca:2a:70 static
# vpp# set ip neighbor avf-0/3a/1/0 192.168.2.1 40:a6:b7:ca:2a:74 static


python3 '/tmp/csit-master/GPL/tools/trex/trex_stl_profile.py' --profile '/tmp/csit-master/GPL/traffic_profiles/trex/trex-stl-ethip4-ip4src253.py' --duration 1.0 --frame_size 64 --rate '1000.0pps' --ports 0 1 --traffic_directions 1 --delay 0.0

# ansible-playbook --vault-password-file=vault_pass --extra-vars '@vault.yml' --inventory inventories/lf_inventory/hosts site.yaml --limit "10.30.51.40" --tags "calico" --extra-vars "calico_vpp_state=absent"





# https://cloudinit.readthedocs.io/en/latest/howto/launch_qemu.html
# https://gist.github.com/morphy2k/819868bee0ca746a7800e66e0b9a93ad
# https://blog.devops.dev/k8s-with-virtualbox-and-cloud-init-8817596f2605