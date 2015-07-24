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

      VmShepherd::Vcloud::Deployer.deploy_and_power_on_vapp(
        client: client,
        ovf_dir: tmpdir,
        vapp_config: vapp_config,
        vdc_name: @vdc_name,
      )
    rescue => e
      logger.error(e.http_body) if e.respond_to?(:http_body)
      raise e
    ensure
      FileUtils.remove_entry_secure(tmpdir, force: true)
    end

    def prepare_environment
    end

    def destroy(vapp_names, catalog)
      VmShepherd::Vcloud::Destroyer.new(client: client, vdc_name: @vdc_name).
        delete_catalog_and_vapps(catalog, vapp_names, @logger)
    end

    def clean_environment(vapp_names, catalog)
      destroy(vapp_names, catalog)
    end

    private

    def check_vapp_status(vapp_config)
      log('Checking for existing VM') do
        ip = vapp_config.ip
        system("ping -c 5 #{ip}") and raise "VM exists at #{ip}"
      end
    end

    def untar_vapp_template_tar(vapp_template_tar_path, dir)
      log("Untarring #{vapp_template_tar_path}") do
        cmd = "cd #{dir} && tar xfv '#{vapp_template_tar_path}'"
        system(cmd) or raise("Error executing: #{cmd}")
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

    def log(title, &blk)
      @logger.debug "--- Begin: #{title.inspect} @ #{DateTime.now}"
      blk.call
      @logger.debug "---   End: #{title.inspect} @ #{DateTime.now}"
    end
  end
end
