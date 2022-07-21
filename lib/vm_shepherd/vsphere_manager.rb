require 'logger'
require 'rbvmomi'

module VmShepherd
  class VsphereManager
    TEMPLATE_PREFIX         = 'tpl'.freeze
    VALID_FOLDER_REGEX      = /\A([\w-]{1,80}\/)*[\w-]{1,80}\/?\z/
    VALID_DISK_FOLDER_REGEX = /\A[\w-]{1,80}\z/

    def initialize(host, username, password, datacenter_name, logger)
      @host            = host
      @username        = username
      @password        = password
      @datacenter_name = datacenter_name
      @logger          = logger
    end

    def deploy(ova_path, vm_config, vsphere_config)
      validate_folder_name!(vsphere_config[:folder])

      ensure_no_running_vm(vm_config)

      ovf_file_path = extract_ovf_from(ova_path)

      boot_vm(ovf_file_path, vm_config, vsphere_config)
    ensure
      FileUtils.remove_entry_secure(ovf_file_path, force: true) unless ovf_file_path.nil?
    end

    def clean_environment(datacenter_folders_to_clean:, datastores:, datastore_folders_to_clean:, cluster_name: nil, resource_pool_name: nil)
      return if datacenter_folders_to_clean.nil? || datastores.nil? || datacenter_folders_to_clean.nil?

      datacenter_folders_to_clean.each do |folder_name|
        validate_folder_name!(folder_name)
        delete_folder_and_vms(folder_name, cluster_name, resource_pool_name)
      end

      datastore_folders_to_clean.each do |folder_name|
        datastores.each do |datastore|
          validate_disk_folder_name!(folder_name)
          begin
            logger.info("BEGIN datastore_folder.destroy_task folder=#{folder_name}")

            file_manager.DeleteDatastoreFile_Task(
              datacenter: datacenter,
              name:       "[#{datastore}] #{folder_name}"
            ).wait_for_completion

            logger.info("END   datastore_folder.destroy_task folder=#{folder_name}")
          rescue RbVmomi::Fault => e
            logger.info("ERROR datastore_folder.destroy_task folder=#{folder_name} #{e.inspect}")
          end
        end
      end
    end

    def prepare_environment
    end

    def destroy(ip_address, resource_pool_name)
      vms = connection.serviceContent.searchIndex.FindAllByIp(ip: ip_address, vmSearch: true)
      vms = vms.select { |vm| resource_pool_name == vm.resourcePool.name } if resource_pool_name
      vms.each do |vm|
        power_off_vm(vm)
        destroy_vm(vm)
      end
    end

    def destroy_vm(vm)
      vm_name = vm.name
      logger.info("BEGIN vm.destroy_task vm=#{vm_name}")
      vm.Destroy_Task.wait_for_completion
      logger.info("END   vm.destroy_task vm=#{vm_name}")
    end

    private

    attr_reader :host, :username, :password, :datacenter_name, :logger

    def validate_disk_folder_name!(folder_name)
      VALID_DISK_FOLDER_REGEX.match(folder_name) || fail("#{folder_name.inspect} is not a valid disk folder name")
    end

    def validate_folder_name!(folder_name)
      VALID_FOLDER_REGEX.match(folder_name) || fail("#{folder_name.inspect} is not a valid folder name")
    end

    def ensure_no_running_vm(vm_config)
      ip_port = "#{vm_config.fetch(:ip)} #{vm_config.fetch(:external_port, 443)}"
      logger.info("BEGIN checking for VM at #{ip_port}")
      fail("VM exists at #{ip_port}") if system("nc -z -w 1 #{ip_port}")
      logger.info("END   checking for VM at #{ip_port}")
    end

    def extract_ovf_from(ova_path)
      logger.info("BEGIN extract_ovf_from #{ova_path}")
      ova_path = File.expand_path(ova_path.strip)

      untar_dir = Dir.mktmpdir

      system("cd #{untar_dir} && tar xfv '#{ova_path}'") || fail("ERROR: Untar'ing #{ova_path}")

      Dir["#{untar_dir}/*.ovf"].first.tap { logger.info("END   extract_ovf_from #{ova_path}") } ||
        fail('Failed to find ovf')
    end

    def create_network_mappings(ovf_file_path, vsphere_config)
      ovf = parse_ovf(ovf_file_path)
      networks = ovf.xpath('//NetworkSection/Network').map { |x| x['name'] }
      Hash[networks.map { |ovf_network| [ovf_network, network(vsphere_config)] }]
    end

    def parse_ovf(ovf_file_path)
      ovf = Nokogiri::XML(File.read(ovf_file_path))
      ovf.remove_namespaces!
      ovf
    end

    def boot_vm(ovf_file_path, vm_config, vsphere_config)
      ensure_folder_exists(vsphere_config[:folder])
      template = deploy_ovf_template(ovf_file_path, vsphere_config)
      vm       = create_vm_from_template(template, vm_config, vsphere_config)

      reconfigure_vm(vm, vm_config, ovf_file_path)
      power_on_vm(vm)
    end

    def ensure_folder_exists(folder_name)
      datacenter.vmFolder.traverse(folder_name, RbVmomi::VIM::Folder, true)
    end

    def delete_folder_and_vms(folder_name, cluster_name = nil, resource_pool_name = nil)
      3.times do |attempt|
        break unless (folder = datacenter.vmFolder.traverse(folder_name))

        find_vms(folder).each do |vm|
          power_off_vm(vm)
          convert_template_to_vm(vm, cluster_name, resource_pool_name)
        end

        begin
          logger.info("BEGIN folder.destroy_task folder=#{folder_name} attempt ##{attempt}")
          folder.Destroy_Task.wait_for_completion
          logger.info("END   folder.destroy_task folder=#{folder_name}")
          fail("#{folder_name.inspect} already exists") unless datacenter.vmFolder.traverse(folder_name).nil?
        rescue RbVmomi::Fault => e
          logger.info("ERROR folder.destroy_task folder=#{folder_name} #{e.inspect}")
          sleep 10
          # give up if it's the 3rd attempt
          raise if attempt == 2
        end
      end
    end


    def find_vms(folder)
      vms = folder.childEntity.grep(RbVmomi::VIM::VirtualMachine)
      vms << folder.childEntity.grep(RbVmomi::VIM::Folder).map { |child| find_vms(child) }
      vms.flatten
    end

    def power_off_vm(vm)
      2.times do
        # This will implicitly skip over VM templates, which always are in the "poweredOff" state
        break if vm.runtime.powerState == 'poweredOff'

        begin
          logger.info("BEGIN vm.power_off_task vm=#{vm.name}, power_state=#{vm.runtime.powerState}")
          vm.PowerOffVM_Task.wait_for_completion
          logger.info("END   vm.power_off_task vm=#{vm.name}")
        rescue StandardError => e
          logger.info("ERROR vm.power_off_task vm=#{vm.name}")
          raise unless e.message.start_with?('InvalidPowerState')
        end
      end
    end

    def convert_template_to_vm(vm, cluster_name, resource_pool_name)
      return unless vm.config.template

      cluster = datacenter.find_compute_resource(cluster_name)
      pool = cluster.resourcePool.resourcePool.find { |rp| rp.name == resource_pool_name }
      vm.MarkAsVirtualMachine(pool: pool)
    end

    def deploy_ovf_template(ovf_file_path, vsphere_config)
      template_name = [TEMPLATE_PREFIX, Time.new.strftime('%F-%H-%M'), cluster(vsphere_config).name].join('-')
      logger.info("BEGIN deploy_ovf ovf_file=#{ovf_file_path} template_name=#{template_name}")

      connection.serviceContent.ovfManager.deployOVF(
        ovf_template_options(ovf_file_path, template_name, vsphere_config)
      ).tap do |ovf_template|
        ovf_template.add_delta_disk_layer_on_all_disks
        ovf_template.MarkAsTemplate
      end
    end

    def ovf_template_options(ovf_file_path, template_name, vsphere_config)
      {
        uri:              ovf_file_path,
        vmName:           template_name,
        vmFolder:         target_folder(vsphere_config),
        host:             find_deploy_host(vsphere_config),
        resourcePool:     resource_pool(vsphere_config),
        datastore:        datastore(vsphere_config),
        networkMappings:  create_network_mappings(ovf_file_path, vsphere_config),
        propertyMappings: {},
      }
    end

    def find_deploy_host(vsphere_config)
      property_collector = connection.serviceContent.propertyCollector

      hosts                   = cluster(vsphere_config).host
      host_properties_by_host =
        property_collector.collectMultiple(
          hosts,
          'datastore',
          'runtime.connectionState',
          'runtime.inMaintenanceMode',
          'name',
        )

      hosts.shuffle.find do |host|
        (host_properties_by_host[host]['runtime.connectionState'] == 'connected') && # connected
          host_properties_by_host[host]['datastore'].member?(datastore(vsphere_config)) && # must have the destination datastore
          !host_properties_by_host[host]['runtime.inMaintenanceMode'] #not be in maintenance mode
      end || fail('ERROR finding host to upload OVF to')
    end

    def create_vm_from_template(template, vm_config, vsphere_config)
      logger.info("BEGIN clone_vm_task template=#{template.name}")
      template.CloneVM_Task(
        folder: target_folder(vsphere_config),
        name:   "#{template.name}-vm",
        spec:   {
          location: {
            pool:         resource_pool(vsphere_config),
            datastore:    datastore(vsphere_config),
            diskMoveType: :moveChildMostDiskBacking,
          },
          powerOn:  false,
          template: false,
          config:   {numCPUs: vm_config[:cpus] || 2, memoryMB: vm_config[:ram_mb] || 4096},
        }
      ).wait_for_completion.tap {
        logger.info("END   clone_vm_task template=#{template.name}")
      }
    end

    def reconfigure_vm(vm, vm_config, ovf_file_path)
      virtual_machine_config_spec = create_virtual_machine_config_spec(vm_config, ovf_file_path)
      logger.info("BEGIN reconfigure_vm_task virtual_machine_config_spec=#{virtual_machine_config_spec.inspect}")
      vm.ReconfigVM_Task(
        spec: virtual_machine_config_spec
      ).wait_for_completion.tap {
        logger.info("END   reconfigure_vm_task virtual_machine_config_spec=#{virtual_machine_config_spec.inspect}")
      }
    end

    def create_virtual_machine_config_spec(vm_config, ovf_file_path)
      logger.info('BEGIN VmConfigSpec creation')
      vm_config_spec =
        RbVmomi::VIM::VmConfigSpec.new.tap do |vcs|
          vcs.ovfEnvironmentTransport = ['com.vmware.guestInfo']
          vcs.property                = create_vapp_property_specs(vm_config, ovf_file_path)
        end
      logger.info("END  VmConfigSpec creation: #{vm_config_spec.inspect}")

      logger.info('BEGIN VirtualMachineConfigSpec creation')
      RbVmomi::VIM::VirtualMachineConfigSpec.new.tap do |virtual_machine_config_spec|
        virtual_machine_config_spec.vAppConfig = vm_config_spec
        logger.info("END  VirtualMachineConfigSpec creation #{virtual_machine_config_spec.inspect}")
      end
    end

    def create_vapp_property_specs(vm_config, ovf_file_path)
      property_value_map = {
        'ip0' => vm_config[:ip],
        'netmask0' => vm_config[:netmask],
        'gateway' => vm_config[:gateway],
        'DNS' => vm_config[:dns],
        'ntp_servers' => vm_config[:ntp_servers],
        'admin_password' => vm_config[:vm_password],
        'public_ssh_key' => vm_config[:public_ssh_key],
        'custom_hostname' => vm_config[:custom_hostname],
      }

      vapp_property_specs = []

      logger.info("BEGIN VAppPropertySpec creation configuration=#{property_value_map.inspect}")

      # VAppPropertySpec order must match OVF template property order
      ovf = parse_ovf(ovf_file_path)
      ovf.xpath('//ProductSection/Property').each_with_index do |property, index|
        label = property.attribute('key').value
        vapp_property_specs << RbVmomi::VIM::VAppPropertySpec.new.tap do |spec|
          spec.operation = 'edit'
          spec.info      = RbVmomi::VIM::VAppPropertyInfo.new.tap do |p|
            p.key   = index
            p.label = label
            p.value = property_value_map[label]
          end
        end
      end

      logger.info("END   VAppPropertySpec creation vapp_property_specs=#{vapp_property_specs.inspect}")
      vapp_property_specs
    end

    def power_on_vm(vm)
      logger.info('BEGIN power_on_vm_task')
      vm.PowerOnVM_Task.wait_for_completion
      logger.info('END  power_on_vm_task')

      Timeout.timeout(20*60) do
        until vm.guest_ip
          logger.info('BEGIN polling for VM IP address')
          sleep 30
        end
        logger.info("END   polling for VM IP address #{vm.guest_ip.inspect}")
      end
    end

    def connection
      RbVmomi::VIM.connect(
        host:     host,
        user:     username,
        password: password,
        ssl:      true,
        insecure: true,
      )
    end

    def datacenter
      connection.searchIndex.FindByInventoryPath(inventoryPath: datacenter_name).tap do |dc|
        fail("ERROR finding datacenter #{datacenter_name.inspect}") unless dc.is_a?(RbVmomi::VIM::Datacenter)
      end
    end

    def file_manager
      connection.serviceContent.fileManager.tap do |fm|
        fail("ERROR finding filemanager") unless fm.is_a?(RbVmomi::VIM::FileManager)
      end
    end

    def target_folder(vsphere_config)
      datacenter.vmFolder.traverse(vsphere_config[:folder], RbVmomi::VIM::Folder, true)
    end

    def cluster(vsphere_config)
      datacenter.find_compute_resource(vsphere_config[:cluster]) ||
        fail("ERROR finding cluster #{vsphere_config[:cluster].inspect}")
    end

    def network(vsphere_config)
      datacenter.networkFolder.traverse(vsphere_config[:network]) ||
        fail("ERROR finding network #{vsphere_config[:network].inspect}")
    end

    def resource_pool(vsphere_config)
      cluster = cluster(vsphere_config)
      if vsphere_config[:resource_pool]
        cluster.resourcePool.resourcePool.find { |rp| rp.name == vsphere_config[:resource_pool] }
      else
        cluster.resourcePool
      end || fail("ERROR finding resource_pool #{vsphere_config[:resource_pool].inspect}")
    end

    def datastore(vsphere_config)
      datacenter.find_datastore(vsphere_config[:datastore]) ||
        fail("ERROR finding datastore #{vsphere_config[:datastore].inspect}")
    end
  end
end
