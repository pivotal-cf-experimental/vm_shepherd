module VmShepherd
  module Vcloud
    class VappConfig
      include VmShepherd::DataObject
      attr_reader :name, :gateway, :dns, :ntp, :ip, :netmask, :catalog, :network

      def initialize(name:, ip:, gateway:, netmask:, dns:, ntp:, catalog:, network:)
        @name = name
        @ip = ip
        @gateway = gateway
        @netmask = netmask
        @dns = dns
        @ntp = ntp
        @catalog = catalog
        @network = network
      end

      def build_properties
        [
          {
            'type' => 'string',
            'key' => 'gateway',
            'value' => gateway,
            'password' => 'false',
            'userConfigurable' => 'true',
            'Label' => 'Default Gateway',
            'Description' => 'The default gateway address for the VM network. Leave blank if DHCP is desired.'
          },
          {
            'type' => 'string',
            'key' => 'DNS',
            'value' => dns,
            'password' => 'false',
            'userConfigurable' => 'true',
            'Label' => 'DNS',
            'Description' => 'The domain name servers for the VM (comma separated). Leave blank if DHCP is desired.',
          },
          {
            'type' => 'string',
            'key' => 'ntp_servers',
            'value' => ntp,
            'password' => 'false',
            'userConfigurable' => 'true',
            'Label' => 'NTP Servers',
            'Description' => 'Comma-delimited list of NTP servers'
          },
          {
            'type' => 'string',
            'key' => 'admin_password',
            'value' => 'tempest',
            'password' => 'true',
            'userConfigurable' => 'true',
            'Label' => 'Admin Password',
            'Description' => 'This password is used to SSH into the VM. The username is "tempest".',
          },
          {
            'type' => 'string',
            'key' => 'ip0',
            'value' => ip,
            'password' => 'false',
            'userConfigurable' => 'true',
            'Label' => 'IP Address',
            'Description' => 'The IP address for the VM. Leave blank if DHCP is desired.',
          },
          {
            'type' => 'string',
            'key' => 'netmask0',
            'value' => netmask,
            'password' => 'false',
            'userConfigurable' => 'true',
            'Label' => 'Netmask',
            'Description' => 'The netmask for the VM network. Leave blank if DHCP is desired.'
          }
        ]
      end
    end
  end
end
