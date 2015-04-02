require 'tmpdir'
require 'fileutils'
require 'rbvmomi'
require 'rbvmomi/utils/deploy'
require 'vm_shepherd/ova_manager/vsphere_clients/cached_ovf_deployer'
require 'vm_shepherd/ova_manager/open_monkey_patch'

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

      def deploy(name_prefix, ova_path, ova_config, location)
        ova_path = File.expand_path(ova_path.strip)
        ensure_no_running_vm(ova_config)

        tmp_dir = untar_vbox_ova(ova_path)
        ovf_path = obtain_ovf_path(tmp_dir)

        deployer = build_deployer(location)
        template = deploy_ovf_template(name_prefix, deployer, ovf_path)
        vm = create_vm_from_template(deployer, template)

        reconfigure_vm(vm, ova_config)
        power_on_vm(vm)
      ensure
        FileUtils.remove_entry_secure(tmp_dir, force: true)
      end

      def find_datacenter(name)
        match = connection.searchIndex.FindByInventoryPath(inventoryPath: name)
        return unless match and match.is_a?(RbVmomi::VIM::Datacenter)
        match
      end

      private

      attr_reader :host, :username, :password, :datacenter_name

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

      def obtain_ovf_path(dir)
        raise 'Failed to find ovf' unless (file_path = Dir["#{dir}/*.ovf"].first)
        "file://#{file_path}"
      end

      def deploy_ovf_template(name_prefix, deployer, ovf_path)
        puts "--- Running: Uploading template @ #{DateTime.now}"
        deployer.upload_ovf_as_template(
          ovf_path,
          Time.new.strftime("#{name_prefix}-%F-%H-%M"),
          run_without_interruptions: true,
        )
      end

      def create_vm_from_template(deployer, template)
        puts "--- Running: Cloning template @ #{DateTime.now}"
        deployer.linked_clone(template, "#{template.name}-vm", {numCPUs: 2, memoryMB: 2048})
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

      def build_deployer(location)
        raise 'Target folder must be set' unless location[:folder]

        unless (datacenter = find_datacenter(datacenter_name))
          raise "Failed to find datacenter '#{datacenter_name}'"
        end

        unless (cluster = datacenter.find_compute_resource(location[:cluster]))
          raise "Failed to find cluster '#{location[:cluster]}'"
        end

        unless (datastore = datacenter.find_datastore(location[:datastore]))
          raise "Failed to find datastore '#{location[:datastore]}'"
        end

        unless (network = datacenter.networkFolder.traverse(location[:network]))
          raise "Failed to find network '#{location[:network]}'"
        end

        resource_pool_name = location[:resource_pool] || location[:resource_pool_name]
        unless (resource_pool = find_resource_pool(cluster, resource_pool_name))
          raise "Failed to find resource pool '#{resource_pool_name}'"
        end

        target_folder = datacenter.vmFolder.traverse(location[:folder], RbVmomi::VIM::Folder, true)

        puts "--- Running: connecting to #{username}@#{host} @ #{DateTime.now}"
        VsphereClients::CachedOvfDeployer.new(
          connection,
          network,
          cluster,
          resource_pool,
          target_folder, # template
          target_folder, # vm
          datastore,
        )
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
