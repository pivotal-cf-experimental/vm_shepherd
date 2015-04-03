require 'tmpdir'
require 'fileutils'
require 'rbvmomi'
require 'rbvmomi/utils/deploy'

module VmShepherd
  module OvaManager
    class Deployer
      attr_reader :location

      def initialize(host, username, password, datacenter_name)
        @host = host
        @username = username
        @password = password
        @datacenter_name = datacenter_name
      end

      def deploy(name_prefix, ova_path, ova_config, vsphere_config)
        raise 'Target folder must be set' unless vsphere_config[:folder]

        fail("Failed to find datacenter '#{datacenter_name}'") unless datacenter

        ova_path = File.expand_path(ova_path.strip)
        ensure_no_running_vm(ova_config)

        tmp_dir = untar_vbox_ova(ova_path)
        ovf_file_path = ovf_file_path_from_dir(tmp_dir)

        template = deploy_ovf_template(name_prefix, ovf_file_path, vsphere_config)
        vm = create_vm_from_template(template, vsphere_config)

        reconfigure_vm(vm, ova_config)
        power_on_vm(vm)
      ensure
        FileUtils.remove_entry_secure(ovf_file_path, force: true)
      end

      private

      attr_reader :host, :username, :password, :datacenter_name

      def datacenter
        @datacenter ||= begin
          match = connection.searchIndex.FindByInventoryPath(inventoryPath: @datacenter_name)
          match if match and match.is_a?(RbVmomi::VIM::Datacenter)
        end
      end

      def connection
        @connection ||= RbVmomi::VIM.connect(
          host: host,
          user: username,
          password: password,
          ssl: true,
          insecure: true,
        )
      end

      def ensure_no_running_vm(ova_config)
        puts "--- Running: Checking for existing VM @ #{DateTime.now}"
        ip = ova_config[:external_ip] || ova_config[:ip]
        port = ova_config[:external_port] || 443
        fail("VM exists at #{ip}") if system("nc -z -w 5 #{ip} #{port}")
      end

      def untar_vbox_ova(ova_path)
        puts "--- Running: Untarring #{ova_path} @ #{DateTime.now}"
        Dir.mktmpdir.tap do |dir|
          system_or_exit("cd #{dir} && tar xfv '#{ova_path}'")
        end
      end

      def ovf_file_path_from_dir(dir)
        Dir["#{dir}/*.ovf"].first || fail('Failed to find ovf')
      end

      def file_path_to_file_uri(file_path)
        "file://#{file_path}"
      end

      def deploy_ovf_template(name_prefix, ovf_file_path, vsphere_config)
        puts "--- Running: Uploading template @ #{DateTime.now}"

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

        puts "Uploading OVF to #{host_properties_by_host[found_host]['name']} @ #{DateTime.now}"

        vm =
          connection.serviceContent.ovfManager.deployOVF(
            uri: file_path_to_file_uri(ovf_file_path),
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

        puts "Marked VM as Template @ #{DateTime.now}"

        vm
      end

      def create_vm_from_template(template, vsphere_config)
        puts "--- Running: Cloning template @ #{DateTime.now}"

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
      end

      def reconfigure_vm(vm, ova_config)
        ip_configuration = {
          'ip0' => ova_config[:ip],
          'netmask0' => ova_config[:netmask],
          'gateway' => ova_config[:gateway],
          'DNS' => ova_config[:dns],
          'ntp_servers' => ova_config[:ntp_servers],
        }

        puts "--- Running: Reconfiguring VM using #{ip_configuration.inspect} @ #{DateTime.now}"
        property_specs = []

        # Order of ip configuration keys must match
        # order of OVF template properties.
        ip_configuration.each_with_index do |(key, value), i|
          property_specs << RbVmomi::VIM::VAppPropertySpec.new.tap do |spec|
            spec.operation = 'edit'
            spec.info = RbVmomi::VIM::VAppPropertyInfo.new.tap do |p|
              p.key = i
              p.label = key
              p.value = value
            end
          end
        end

        property_specs << RbVmomi::VIM::VAppPropertySpec.new.tap do |spec|
          spec.operation = 'edit'
          spec.info = RbVmomi::VIM::VAppPropertyInfo.new.tap do |p|
            p.key = ip_configuration.length
            p.label = 'admin_password'
            p.value = ova_config[:vm_password]
          end
        end

        vm_config_spec = RbVmomi::VIM::VmConfigSpec.new
        vm_config_spec.ovfEnvironmentTransport = ['com.vmware.guestInfo']
        vm_config_spec.property = property_specs

        vmachine_spec = RbVmomi::VIM::VirtualMachineConfigSpec.new
        vmachine_spec.vAppConfig = vm_config_spec
        vm.ReconfigVM_Task(spec: vmachine_spec).wait_for_completion
      end

      def power_on_vm(vm)
        puts "--- Running: Powering on VM @ #{DateTime.now}"
        vm.PowerOnVM_Task.wait_for_completion
        wait_for('VM IP') { vm.guest_ip }
      end

      def target_folder(vsphere_config)
        datacenter.vmFolder.traverse(vsphere_config[:folder], RbVmomi::VIM::Folder, true)
      end

      def cluster(vsphere_config)
        datacenter.find_compute_resource(vsphere_config[:cluster]) ||
          fail("Failed to find cluster '#{vsphere_config[:cluster]}'")
      end

      def network(vsphere_config)
        datacenter.networkFolder.traverse(vsphere_config[:network]) ||
          fail("Failed to find network '#{vsphere_config[:network]}'")
      end

      def resource_pool(vsphere_config)
        find_resource_pool(cluster(vsphere_config), vsphere_config[:resource_pool]) ||
          fail("Failed to find resource pool '#{vsphere_config[:resource_pool]}'")
      end

      def datastore(vsphere_config)
        datacenter.find_datastore(vsphere_config[:datastore]) ||
          fail("Failed to find datastore '#{vsphere_config[:datastore]}'")
      end

      def find_resource_pool(cluster, resource_pool_name)
        if resource_pool_name
          cluster.resourcePool.resourcePool.find { |rp| rp.name == resource_pool_name }
        else
          cluster.resourcePool
        end
      end

      def system_or_exit(*args)
        puts "--- Running: #{args} @ #{DateTime.now}"
        system(*args) || fail('FAILED')
      end

      def wait_for(title, &blk)
        Timeout.timeout(7*60) do
          until (value = blk.call)
            puts '--- Waiting for 30 secs'
            sleep 30
          end
          puts "--- Value obtained for #{title} is #{value}"
          value
        end
      rescue Timeout::Error
        puts "--- Timed out waiting for #{title}"
        raise
      end
    end
  end
end
