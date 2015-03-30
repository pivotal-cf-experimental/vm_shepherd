require 'fog'

module VmShepherd
  class OpenstackVmManager
    def initialize(auth_url:, username:, api_key:, tenant:)
      @auth_url = auth_url
      @username = username
      @api_key = api_key
      @tenant = tenant
    end

    def deploy(qcow2_file_path, vm_options)
      say "Uploading the image #{qcow2_file_path}"
      image = image_service.images.create(
        name: vm_options[:name],
        size: File.size(qcow2_file_path),
        disk_format: 'qcow2',
        container_format: 'bare',
        location: qcow2_file_path,
      )
      say 'Finished uploading the image'

      flavor = find_flavor(vm_options[:min_disk_size])
      network = network_service.networks.find { |net| net.name == vm_options[:network_name] }
      security_groups = vm_options[:security_group_names]

      say('Launching an instance')
      server = service.servers.create(
        name: vm_options[:name],
        flavor_ref: flavor.id,
        image_ref: image.id,
        key_name: vm_options[:key_name],
        security_groups: security_groups,
        nics: [{net_id: network.id}],
      )
      server.wait_for { ready? }
      say('Finished launching an instance')

      say('Assigning an IP to the instance')
      ip = service.addresses.find { |address| address.instance_id.nil? && address.ip == vm_options[:ip] }
      ip.server = server
      say('Finished assigning an IP to the instance')
    end

    def destroy(vm_options)
      ip = service.addresses.find { |address| address.ip == vm_options[:ip] }
      server = service.servers.get(ip.instance_id)
      image = image_service.images.get(server.image['id'])

      server.destroy
      image.destroy
    end

    def service
      @service ||= Fog::Compute.new(
        provider: 'openstack',
        openstack_auth_url: auth_url,
        openstack_username: username,
        openstack_tenant: tenant,
        openstack_api_key: api_key,
      )
    end

    def image_service
      @image_service ||= Fog::Image.new(
        provider: 'openstack',
        openstack_auth_url: auth_url,
        openstack_username: username,
        openstack_tenant: tenant,
        openstack_api_key: api_key,
        openstack_endpoint_type: 'publicURL',
      )
    end

    def network_service
      @network_service ||= Fog::Network.new(
        provider: 'openstack',
        openstack_auth_url: auth_url,
        openstack_username: username,
        openstack_tenant: tenant,
        openstack_api_key: api_key,
        openstack_endpoint_type: 'publicURL',
      )
    end

    private

    attr_reader :auth_url, :username, :api_key, :tenant

    def say(message)
      puts message
    end

    def find_flavor(min_disk)
      service.flavors.find { |flavor| flavor.disk >= min_disk }
    end
  end
end
