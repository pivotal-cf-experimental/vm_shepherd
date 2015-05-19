require 'tmpdir'
require 'fileutils'
require 'ruby_vcloud_sdk'

module VmShepherd
  class VcloudManager
    def initialize(login_info, vdc_name, logger)
      @login_info = login_info
      @vdc_name = vdc_name
      @logger = logger
    end

    def deploy(vapp_template_tar_path, vapp_config)
      tmpdir = Dir.mktmpdir

      check_vapp_status(vapp_config)

      untar_vapp_template_tar(File.expand_path(vapp_template_tar_path), tmpdir)

      vapp = deploy_vapp(tmpdir, vapp_config)
      reconfigure_vm(vapp, vapp_config)
      vapp.power_on
    ensure
      FileUtils.remove_entry_secure(tmpdir, force: true)
    end

    def prepare_environment
    end

    def destroy(vapp_names, catalog)
      delete_vapps(vapp_names)
      delete_catalog(catalog)
    end

    def clean_environment(vapp_names, catalog)
      destroy(vapp_names, catalog)
    end

    private

    def check_vapp_status(vapp_config)
      log('Checking for existing VM') do
        ip = vapp_config[:ip]
        raise "VM exists at #{ip}" if system("ping -c 5 #{ip}")
      end
    end

    def untar_vapp_template_tar(vapp_template_tar_path, dir)
      log("Untarring #{vapp_template_tar_path}") do
        system_or_exit("cd #{dir} && tar xfv '#{vapp_template_tar_path}'")
      end
    end

    def client
      @client ||= VCloudSdk::Client.new(
        @login_info[:url],
        "#{@login_info[:user]}@#{@login_info[:organization]}",
        @login_info[:password],
        {},
        @logger,
      )
    end

    def deploy_vapp(ovf_dir, vapp_config)
      vapp_name = vapp_config.fetch(:name)
      catalog_name = vapp_config.fetch(:catalog)
      network = vapp_config.fetch(:network)
      # setup the catalog
      client.delete_catalog_by_name(catalog_name) if client.catalog_exists?(catalog_name)
      catalog = client.create_catalog(catalog_name)

      # upload template and instantiate vapp
      catalog.upload_vapp_template(@vdc_name, vapp_name, ovf_dir)

      # instantiate template
      network_config = VCloudSdk::NetworkConfig.new(network, 'Network 1')
      catalog.instantiate_vapp_template(vapp_name, @vdc_name, vapp_name, nil, nil, network_config)
    rescue => e
      @logger.error(e.http_body) if e.respond_to?(:http_body)
      raise e
    end

    def reconfigure_vm(vapp, vapp_config)
      vapp_name = vapp_config.fetch(:name)
      gateway = vapp_config.fetch(:gateway)
      dns = vapp_config.fetch(:dns)
      ntp = vapp_config.fetch(:ntp)
      ip = vapp_config.fetch(:ip)
      netmask = vapp_config.fetch(:netmask)

      vm = vapp.find_vm_by_name(vapp_name)
      vm.product_section_properties = build_properties(gateway: gateway, dns: dns, ntp: ntp, ip: ip, netmask: netmask)
      vm
    end

    def build_properties(gateway:, dns:, ntp:, ip:, netmask:)
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

    def log(title, &blk)
      @logger.debug "--- Begin: #{title.inspect} @ #{DateTime.now}"
      blk.call
      @logger.debug "---   End: #{title.inspect} @ #{DateTime.now}"
    end

    def system_or_exit(command)
      log(command) do
        system(command) || raise("Error executing: #{command.inspect}")
      end
    end

    def vdc
      @vdc ||= client.find_vdc_by_name(@vdc_name)
    end

    def delete_vapps(vapp_names)
      vapp_names.each do |vapp_name|
        begin
          vapp = vdc.find_vapp_by_name(vapp_name)
          vapp.power_off
          vapp.delete
        rescue VCloudSdk::ObjectNotFoundError => e
          @logger.debug "Could not delete vapp '#{vapp_name}': #{e.inspect}"
        end
      end
    end

    def delete_catalog(catalog)
      client.delete_catalog_by_name(catalog) if client.catalog_exists?(catalog)
    end
  end
end
