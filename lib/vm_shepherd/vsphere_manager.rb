require 'logger'
require 'rbvmomi'

module VmShepherd
  class VsphereManager
    TEMPLATE_PREFIX = 'tpl'.freeze

    def initialize(host, username, password, datacenter_name)
      @host = host
      @username = username
      @password = password
      @datacenter_name = datacenter_name
      @logger = Logger.new(STDERR)
    end

    def deploy(ova_path, vm_config, vsphere_config)
      raise ArgumentError unless folder_name_is_valid?(vsphere_config[:folder])

      ova_path = File.expand_path(ova_path.strip)
      ensure_no_running_vm(vm_config)

      tmp_dir = untar_vbox_ova(ova_path)
      ovf_file_path = ovf_file_path_from_dir(tmp_dir)

      template = deploy_ovf_template(TEMPLATE_PREFIX, ovf_file_path, vsphere_config)
      vm = create_vm_from_template(template, vsphere_config)

      reconfigure_vm(vm, vm_config)
      power_on_vm(vm)
    ensure
      FileUtils.remove_entry_secure(ovf_file_path, force: true) unless ovf_file_path.nil?
    end

    def destroy(folder_name)
      fail("#{folder_name.inspect} is not a valid folder name") unless folder_name_is_valid?(folder_name)

      delete_folder_and_vms(folder_name)

      fail("#{folder_name.inspect} already exists") unless datacenter.vmFolder.traverse(folder_name).nil?

      datacenter.vmFolder.traverse(folder_name, RbVmomi::VIM::Folder, true)
    end

    private

    attr_reader :host, :username, :password, :datacenter_name, :logger

    def delete_folder_and_vms(folder_name)
      return unless (folder = datacenter.vmFolder.traverse(folder_name))

      find_vms(folder).each { |vm| power_off(vm) }

      logger.info("BEGIN folder.destroy_task folder=#{folder_name}")
      folder.Destroy_Task.wait_for_completion
      logger.info("END   folder.destroy_task folder=#{folder_name}")
    rescue RbVmomi::Fault => e
      logger.info("ERROR folder.destroy_task folder=#{folder_name}", e)
      raise
    end

    def find_vms(folder)
      vms = folder.childEntity.grep(RbVmomi::VIM::VirtualMachine)
      vms << folder.childEntity.grep(RbVmomi::VIM::Folder).map { |child| find_vms(child) }
      vms.flatten
    end

    def power_off(vm)
      2.times do
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

    def folder_name_is_valid?(folder_name)
      /\A([\w-]{1,80}\/)*[\w-]{1,80}\/?\z/.match(folder_name)
    end

    def ensure_no_running_vm(ova_config)
      logger.info('--- Running: Checking for existing VM')
      ip = ova_config[:external_ip] || ova_config[:ip]
      port = ova_config[:external_port] || 443
      fail("VM exists at #{ip}") if system("nc -z -w 5 #{ip} #{port}")
    end

    def untar_vbox_ova(ova_path)
      logger.info("--- Running: Untarring #{ova_path}")
      Dir.mktmpdir.tap do |dir|
        system_or_exit("cd #{dir} && tar xfv '#{ova_path}'")
      end
    end

    def ovf_file_path_from_dir(dir)
      Dir["#{dir}/*.ovf"].first || fail('Failed to find ovf')
    end

    def deploy_ovf_template(name_prefix, ovf_file_path, vsphere_config)
      logger.info('--- Running: Uploading template')

      ovf = Nokogiri::XML(File.read(ovf_file_path))
      ovf.remove_namespaces!
      networks = ovf.xpath('//NetworkSection/Network').map { |x| x['name'] }
      network_mappings = Hash[networks.map { |ovf_network| [ovf_network, network(vsphere_config)] }]

      property_collector = connection.serviceContent.propertyCollector

      hosts = cluster(vsphere_config).host
      host_properties_by_host =
        property_collector.collectMultiple(
          hosts,
          'datastore',
          'runtime.connectionState',
          'runtime.inMaintenanceMode',
          'name',
        )

      found_host = # OVFs need to be uploaded to a specific host. The host needs to be:
        hosts.shuffle.find do |host|
          (host_properties_by_host[host]['runtime.connectionState'] == 'connected') && # connected
            host_properties_by_host[host]['datastore'].member?(datastore(vsphere_config)) && # must have the destination datastore
            !host_properties_by_host[host]['runtime.inMaintenanceMode'] #not be in maintenance mode
        end || fail('No host in the cluster available to upload OVF to')

      logger.info("BEGIN deploy_ovf ovf_file=#{ovf_file_path} host=#{host_properties_by_host[found_host]['name']}")

      vm =
        connection.serviceContent.ovfManager.deployOVF(
          uri: ovf_file_path,
          vmName: "#{Time.new.strftime("#{name_prefix}-%F-%H-%M")}-#{cluster(vsphere_config).name}",
          vmFolder: target_folder(vsphere_config),
          host: found_host,
          resourcePool: resource_pool(vsphere_config),
          datastore: datastore(vsphere_config),
          networkMappings: network_mappings,
          propertyMappings: {},
        )
      vm.add_delta_disk_layer_on_all_disks
      vm.MarkAsTemplate

      logger.info("END   deploy_ovf ovf_file=#{ovf_file_path} host=#{host_properties_by_host[found_host]['name']}")

      vm
    end

    def create_vm_from_template(template, vsphere_config)
      logger.info("BEGIN clone_vm_task tempalte=#{template.name}")
      template.CloneVM_Task(
        folder: target_folder(vsphere_config),
        name: "#{template.name}-vm",
        spec: {
          location: {
            pool: resource_pool(vsphere_config),
            datastore: datastore(vsphere_config),
            diskMoveType: :moveChildMostDiskBacking,
          },
          powerOn: false,
          template: false,
          config: {numCPUs: 2, memoryMB: 2048},
        }
      ).wait_for_completion
      logger.info("END   clone_vm_task tempalte=#{template.name}")
    end

    def reconfigure_vm(vm, vm_config)
      virtual_machine_config_spec = create_virtual_machine_config_spec(vm_config)
      logger.info("BEGIN reconfigure_vm_task virtual_machine_cofig_spec=#{virtual_machine_config_spec.inspect}")
      vm.ReconfigVM_Task(spec: virtual_machine_config_spec).wait_for_completion
      logger.info("END   reconfigure_vm_task virtual_machine_cofig_spec=#{virtual_machine_config_spec.inspect}")
    end

    def create_virtual_machine_config_spec(vm_config)
      ip_configuration = {
        'ip0' => vm_config[:ip],
        'netmask0' => vm_config[:netmask],
        'gateway' => vm_config[:gateway],
        'DNS' => vm_config[:dns],
        'ntp_servers' => vm_config[:ntp_servers],
      }

      vapp_property_specs = []

      logger.info("BEGIN VAppPropertySpec creation configuration=#{ip_configuration.inspect}")
      # IP Configuration key order must match OVF template property order
      ip_configuration.each_with_index do |(key, value), i|
        vapp_property_specs << RbVmomi::VIM::VAppPropertySpec.new.tap do |spec|
          spec.operation = 'edit'
          spec.info = RbVmomi::VIM::VAppPropertyInfo.new.tap do |p|
            p.key = i
            p.label = key
            p.value = value
          end
        end
      end

      vapp_property_specs << RbVmomi::VIM::VAppPropertySpec.new.tap do |spec|
        spec.operation = 'edit'
        spec.info = RbVmomi::VIM::VAppPropertyInfo.new.tap do |p|
          p.key = ip_configuration.length
          p.label = 'admin_password'
          p.value = vm_config[:vm_password]
        end
      end
      logger.info("END   VAppPropertySpec creation vapp_property_specs=#{vapp_property_specs.inspect}")

      logger.info('BEGIN VmConfigSpec creation')
      vm_config_spec = RbVmomi::VIM::VmConfigSpec.new
      vm_config_spec.ovfEnvironmentTransport = ['com.vmware.guestInfo']
      vm_config_spec.property = vapp_property_specs
      logger.info("END  VmConfigSpec creation: #{vm_config_spec.inspect}")

      logger.info('BEGIN VirtualMachineConfigSpec creation')
      virtual_machine_config_spec = RbVmomi::VIM::VirtualMachineConfigSpec.new
      virtual_machine_config_spec.vAppConfig = vm_config_spec
      logger.info("END  VirtualMachineConfigSpec creation #{virtual_machine_config_spec.inspect}")
      virtual_machine_config_spec
    end

    def power_on_vm(vm)
      logger.info('BEGIN power_on_vm_task')
      vm.PowerOnVM_Task.wait_for_completion
      logger.info('END  power_on_vm_task')

      Timeout.timeout(7*60) do
        until vm.guest_ip
          logger.info('BEGIN polling for VM IP address')
          sleep 30
        end
        logger.info("END   polling for VM IP address #{vm.guest_ip.inspect}")
      end
    end

    def connection
      RbVmomi::VIM.connect(
        host: host,
        user: username,
        password: password,
        ssl: true,
        insecure: true,
      )
    end

    def datacenter
      connection.searchIndex.FindByInventoryPath(inventoryPath: datacenter_name).tap do |dc|
        fail("ERROR finding datacenter #{datacenter_name.inspect}") unless dc.is_a?(RbVmomi::VIM::Datacenter)
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
      find_resource_pool(cluster(vsphere_config), vsphere_config[:resource_pool]) ||
        fail("ERROR finding resource_pool #{vsphere_config[:resource_pool].inspect}")
    end

    def datastore(vsphere_config)
      datacenter.find_datastore(vsphere_config[:datastore]) ||
        fail("ERROR finding datastore #{vsphere_config[:datastore].inspect}")
    end

    def find_resource_pool(cluster, resource_pool_name)
      if resource_pool_name
        cluster.resourcePool.resourcePool.find { |rp| rp.name == resource_pool_name }
      else
        cluster.resourcePool
      end
    end

    def system_or_exit(command)
      logger.info("BEGIN running #{command.inspect}")
      system(command) || fail("ERROR running #{command.inspect}")
      logger.info("END   running #{command.inspect}")
    end
  end
end
