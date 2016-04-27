require 'fog'
require 'vm_shepherd/retry_helper'

module VmShepherd
  class OpenstackManager
    include VmShepherd::RetryHelper

    def initialize(auth_url:, username:, api_key:, tenant:)
      @auth_url = auth_url
      @username = username
      @api_key = api_key
      @tenant = tenant
    end

    def deploy(raw_file_path, vm_options)
      say "Uploading the image #{raw_file_path}"
      image = image_service.images.create(
        name: "#{vm_options[:name]} #{Time.now}",
        size: File.size(raw_file_path),
        disk_format: 'raw',
        container_format: 'bare',
        location: raw_file_path,
      )
      say 'Finished uploading the image'

      flavor = find_flavor(vm_options[:flavor_name])
      network = network_service.networks.find { |net| net.name == vm_options[:network_name] }
      security_groups = vm_options[:security_group_names]

      say('Launching an instance')
      server = service.servers.create(
        name: vm_options[:name],
        flavor_ref: flavor.id,
        image_ref: image.id,
        key_name: vm_options[:key_name],
        security_groups: security_groups,
        nics: [
          {net_id: network.id, v4_fixed_ip: vm_options[:private_ip]}
        ],
      )
      server.wait_for { ready? }
      say('Finished launching an instance')

      say('Assigning a Public IP to the instance')
      ip = service.addresses.find { |address| address.instance_id.nil? && address.ip == vm_options[:public_ip] }
      ip.server = server
      say('Finished assigning a Public IP to the instance')
    end

    def destroy(vm_options)
      say('Destroying Ops Manager instances')

      server = service.servers.find { |srv| srv.name == vm_options[:name] }
      if server
        say("Found running Ops Manager instance #{server.id}")
        server.destroy
        retry_until(retry_limit: 30) do
          say("  Waiting for #{vm_options[:name]} server to be destroyed")
          service.servers.find { |srv| srv.name == vm_options[:name] }.nil?
        end
        say('Ops Manager instance destroyed')
      end

      image_service.images.each do |image|
        next unless /^#{vm_options[:name]} \d+/ =~ image.name && image.status != 'deleted'
        say("Found an Ops Manager image for env [#{vm_options[:name]}]: [#{image.id}][#{image.name}]")
        image.destroy
        say('Ops Manager image destroyed')
      end
      say('Done destroying Ops Manager instances')
    end

    def clean_environment
      say("Destroying #{service.servers.size} instances:")
      retry_until(retry_limit: 2) do
        begin
          service.servers.each do |server|
            server.volumes.each do |volume|
              say("  Detaching volume #{volume.id} from server #{server.id}")
              server.detach_volume(volume.id)
              volume.wait_for { volume.ready? }
            end

            say("  Destroying instance #{server.id}")
            server.destroy
          end

          retry_until(retry_limit: 15) do
            server_count = service.servers.count
            say("  Waiting for #{server_count} servers to be destroyed")
            server_count == 0
          end

          private_images = image_service.images.reject(&:is_public)

          say("Destroying #{private_images.size} images:")
          private_images.each do |image|
            next if image.status == 'deleted'
            say("  Destroying image #{image.id}")
            image.destroy
          end

          say("Destroying #{service.volumes.size} volumes:")
          service.volumes.each do |volume|
            say("  Destroying volume #{volume.id}; current status: [#{volume.status}]")
            volume.wait_for { volume.ready? }
            volume.destroy
          end

          say("Destroying contents of #{storage_service.directories.size} containers:")
          storage_service.directories.each do |directory|
            say("  Destroying #{directory.files.size} files from #{directory.key}")
            directory.files.each do |file|
              say("    Destroying file #{file.key}")
              file.destroy
            end
          end
        rescue VmShepherd::RetryHelper::RetryLimitExceeded, Fog::Errors::TimeoutError => e
          say("Going to retry to cleanup again. First attempt raised #{e.class}: #{e.message}")
        end
      end
    end

    def prepare_environment
    end

    def connection_options
      {
        :ssl_verify_peer => false
      }
    end

    def service
      @service ||= Fog::Compute.new(
        provider: 'openstack',
        openstack_auth_url: auth_url,
        openstack_username: username,
        openstack_tenant: tenant,
        openstack_api_key: api_key,
        connection_options: connection_options,
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
        connection_options: connection_options,
      )
    end

    def network_service
      @network_service ||= Fog::Network.new(
        provider: 'openstack',
        openstack_auth_url: auth_url,
        openstack_username: username,
        openstack_tenant: tenant,
        openstack_api_key: api_key,
        connection_options: connection_options,
      )
    end

    def storage_service
      @network_service ||= Fog::Storage.new(
        provider: 'openstack',
        openstack_auth_url: auth_url,
        openstack_username: username,
        openstack_tenant: tenant,
        openstack_api_key: api_key,
        connection_options: connection_options,
      )
    end

    private

    attr_reader :auth_url, :username, :api_key, :tenant

    def say(message)
      puts message
    end

    def find_flavor(flavor_name)
      service.flavors.find { |flavor| flavor.name == flavor_name }
    end
  end
end
