#!/bin/bash

function create_network_staffs_on_east_and_west
{
   export TENANT_ID=$(openstack project list |grep $OS_PROJECT_NAME |awk '{print $2}')
   export EXT_NET_ID=$(neutron net-list |grep ' ext_net ' |awk '{print $2}')

   neutron net-create vpn-net-east --provider:network_type gre --provider:segmentation_id 1012
   neutron subnet-create --tenant_id $TENANT_ID --ip_version 4 --gateway 192.168.2.1 vpn-net-east 192.168.2.0/24
   neutron router-create --tenant_id $TENANT_ID vpn-router-east
   export EAST_ROUTER_ID=$(neutron router-list |grep ' vpn-router-east ' |awk '{print $2}')
   export EAST_SUBNET_ID=$(neutron subnet-list |grep '192.168.2.0/24' |awk '{print $2}')
   neutron router-interface-add $EAST_ROUTER_ID $EAST_SUBNET_ID
   neutron router-gateway-set $EAST_ROUTER_ID $EXT_NET_ID

   neutron net-create vpn-net-west --provider:network_type gre --provider:segmentation_id 1013
   neutron subnet-create --tenant_id $TENANT_ID --ip_version 4 --gateway 192.168.3.1 vpn-net-west 192.168.3.0/24
   neutron router-create --tenant_id $TENANT_ID vpn-router-west
   export WEST_ROUTER_ID=$(neutron router-list |grep ' vpn-router-west ' |awk '{print $2}')
   export WEST_SUBNET_ID=$(neutron subnet-list |grep '192.168.3.0/24' |awk '{print $2}')
   neutron router-interface-add $WEST_ROUTER_ID $WEST_SUBNET_ID
   neutron router-gateway-set $WEST_ROUTER_ID $EXT_NET_ID
}

function create_two_VMs_on_east_and_west
{
   nova keypair-add --pub-key ~/.ssh/id_rsa.pub mykey
   export IMAGE_ID=$(nova image-list |grep 'xenial' |awk '{print $2}')
   nova secgroup-add-rule default tcp 22 22 0.0.0.0/0
   nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0

   export EAST_NET_ID=$(neutron net-list |grep ' vpn-net-east ' |awk '{print $2}')
   time nova boot --poll --key-name mykey --image $IMAGE_ID --flavor m1.small --nic net-id=$EAST_NET_ID vpn-vm-east
   export EAST_VM_ID=$(nova list |grep 'vpn-vm-east' |awk '{print $2}')
   FLOATING_IP_EAST=$(nova floating-ip-create |grep ' ext_net ' |awk '{print $4}')
   nova floating-ip-associate $EAST_VM_ID $FLOATING_IP_EAST

   export WEST_NET_ID=$(neutron net-list |grep ' vpn-net-west ' |awk '{print $2}')
   time nova boot --poll --key-name mykey --image $IMAGE_ID --flavor m1.small --nic net-id=$WEST_NET_ID vpn-vm-west
   export WEST_VM_ID=$(nova list |grep 'vpn-vm-west' |awk '{print $2}')
   export FLOATING_IP_WEST=$(nova floating-ip-create |grep 'ext_net' |awk '{print $4}')
   nova floating-ip-associate $WEST_VM_ID $FLOATING_IP_WEST
}

function create_vpn_staffs_on_east_and_west
{
   export EAST_EXT_IP=$(neutron router-show vpn-router-east |grep 'external_gateway_info' |grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
   export WEST_EXT_IP=$(neutron router-show vpn-router-west |grep 'external_gateway_info' |grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
   neutron vpn-ikepolicy-create ikepolicy1
   neutron vpn-ipsecpolicy-create ipsecpolicy1

   neutron vpn-service-create --name vpn-east --description "VPN EAST" $EAST_ROUTER_ID $EAST_SUBNET_ID
   neutron ipsec-site-connection-create --name vpn_conn_east --vpnservice-id vpn-east --ikepolicy-id ikepolicy1 --ipsecpolicy-id ipsecpolicy1 --peer-address $WEST_EXT_IP --peer-id $WEST_EXT_IP --peer-cidr 192.168.3.0/24 --psk password

   neutron vpn-service-create --name vpn-west --description "VPN WEST" $WEST_ROUTER_ID $WEST_SUBNET_ID
   neutron ipsec-site-connection-create --name  vpn_conn_west --vpnservice-id vpn-west --ikepolicy-id ikepolicy1 --ipsecpolicy-id ipsecpolicy1 --peer-address $EAST_EXT_IP --peer-id $EAST_EXT_IP --peer-cidr 192.168.2.0/24 --psk password
}

function configure
{
   create_network_staffs_on_east_and_west
   create_two_VMs_on_east_and_west
   create_vpn_staffs_on_east_and_west
}


function status
{
  neutron ipsec-site-connection-list
  neutron vpn-service-list
}

function disable
{
  neutron vpn-service-update --admin_state_up=False `neutron vpn-service-list |grep 'vpn-east' |awk '{print $2}'`
}

function enable
{
  neutron vpn-service-update --admin_state_up=True `neutron vpn-service-list |grep 'vpn-east' |awk '{print $2}'`
}

function ping
{
  FLOATING_IP_EAST=$(nova list |grep 'vpn-vm-east' |awk -F ',' '{print $2}' |awk '{print $1}')
  VM_WEST_IP=$(nova list |grep 'vpn-vm-west' |awk -F '=' '{print $2}' |awk -F ',' '{print $1}')
  ssh -o StrictHostKeyChecking=no -i mykey ubuntu@$FLOATING_IP_EAST ping $VM_WEST_IP
}

function debug
{
  export EAST_ROUTER_ID=$(neutron router-list |grep ' vpn-router-east ' |awk '{print $2}')
  export WEST_ROUTER_ID=$(neutron router-list |grep ' vpn-router-west ' |awk '{print $2}')
  juju run --unit neutron-gateway/0 -- sudo ip netns exec qrouter-$EAST_ROUTER_ID iptables -nL -t nat |grep ipsec
  juju run --unit neutron-gateway/0 -- sudo ip netns exec qrouter-$WEST_ROUTER_ID iptables -nL -t nat |grep ipsec
  juju run --unit neutron-gateway/0 -- sudo ip netns exec qrouter-$EAST_ROUTER_ID ip route list table 220
  juju run --unit neutron-gateway/0 -- sudo ip netns exec qrouter-$WEST_ROUTER_ID ip route list table 220
  juju run --unit neutron-gateway/0 -- sudo /usr/bin/neutron-rootwrap /etc/neutron/rootwrap.conf ip netns exec qrouter-$EAST_ROUTER_ID neutron-vpn-netns-wrapper --mount_paths=/etc:/var/lib/neutron/ipsec/$EAST_ROUTER_ID/etc,/var/run:/var/lib/neutron/ipsec/$EAST_ROUTER_ID/var/run --cmd=ipsec,status
  juju run --unit neutron-gateway/0 -- sudo /usr/bin/neutron-rootwrap /etc/neutron/rootwrap.conf ip netns exec qrouter-$WEST_ROUTER_ID neutron-vpn-netns-wrapper --mount_paths=/etc:/var/lib/neutron/ipsec/$WEST_ROUTER_ID/etc,/var/run:/var/lib/neutron/ipsec/$WEST_ROUTER_ID/var/run --cmd=ipsec,status
}

function usage
{
  echo "Usage: ./configure_vpnaas.sh      <command>"
  echo "<commands>"
  echo "configure:    configure vpn env with two tunnels in two routers"
  echo "status:       the status of vpnservice and ipsec-site-connection"
  echo "disable       disable a vpnservice"
  echo "enable        enable a vpnservice"
  echo "ssh           ssh into one vm"
  echo "debug         debug"
  echo "all           all"
}


function all
{
  configure
  status
  debug
  ping
  status
  debug
}

if [ ! -f ~/.ssh/id_rsa.pub ]; then
  echo "your ~/.ssh/id_rsa.pub doesn't exsit, pls use 'ssh-keygen -t rsa' command to create it first, exit..."
  exit
fi

case "$1" in 
'configure')         configure
                   ;;
'status')          status
                   ;;
'disable')         disable
                   ;;
'enable')          enable
                   ;;
'ping')            ping
                   ;;
'debug')            debug
                   ;;
'all')             all
                   ;;
*) usage
   ;;
esac
