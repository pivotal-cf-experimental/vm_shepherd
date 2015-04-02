require 'open-uri'
require 'nokogiri'
require 'rbvmomi'

module VsphereClients
  class CachedOvfDeployer
    attr_reader :resource_pool, :cluster

    # Constructor. Gets the VIM connection and important VIM objects
    # @param connection [VIM] VIM Connection
    # @param network [VIM::Network] Network to attach templates and VMs to
    # @param cluster [VIM::ComputeResource] Host/Cluster to deploy templates/VMs to
    # @param folder [VIM::Folder] Folder in which all templates are kept
    # @param datastore [VIM::Folder] Datastore to store template/VM in
    def initialize(connection, network, cluster, resource_pool, folder, datastore)
      @connection = connection
      @network = network
      @cluster = cluster
      @resource_pool = resource_pool
      @folder = folder
      @datastore = datastore
    end

    # Uploads an OVF, prepares the resulting VM for linked cloning and then marks
    # it as a template. If another thread happens to race to do the same task,
    # the losing thread will not do the actual work, but instead wait for the
    # winning thread to do the work by looking up the template VM and waiting for
    # it to be marked as a template. This way, the cost of uploading and keeping
    # the full size of the VM is only paid once.
    # @param ovf_url [String] URL to the OVF to be deployed. Currently only http
    #                         and https are supported
    # @param template_name [String] Name of the template to be used. Should be the
    #                               same name for the same URL. A cluster specific
    #                               post-fix will automatically be added.
    # @option opts [int]  :run_without_interruptions Whether or not to disable
    #                                                SIGINT and SIGTERM during
    #                                                the OVF upload.
    # @return [VIM::VirtualMachine] The template as a VIM::VirtualMachine instance
    def upload_ovf_as_template(ovf_url, template_name)
      # The OVFManager expects us to know the names of the networks mentioned
      # in the OVF file so we can map them to VIM::Network objects. For
      # simplicity this function assumes we need to read the OVF file
      # ourselves to know the names, and we map all of them to the same
      # VIM::Network.
      ovf = open(ovf_url, 'r') { |io| Nokogiri::XML(io.read) }
      ovf.remove_namespaces!
      networks = ovf.xpath('//NetworkSection/Network').map { |x| x['name'] }
      network_mappings = Hash[networks.map { |x| [x, @network] }]

      puts "networks: #{network_mappings.inspect} @ #{DateTime.now}"

      property_collector = @connection.serviceContent.propertyCollector

      hosts = @cluster.host
      host_properties_by_host =
        property_collector.collectMultiple(
          hosts,
          'datastore',
          'runtime.connectionState',
          'runtime.inMaintenanceMode',
          'name',
        )

      # OVFs need to be uploaded to a specific host. The host needs to be:
      found_host =
        hosts.shuffle.find do |host|
          (host_properties_by_host[host]['runtime.connectionState'] == 'connected') && # connected
            host_properties_by_host[host]['datastore'].member?(@datastore) && # must have the destination datastore
            !host_properties_by_host[host]['runtime.inMaintenanceMode'] #not be in maintenance mode
        end

      if !found_host
        fail 'No host in the cluster available to upload OVF to'
      end

      puts "Uploading OVF to #{host_properties_by_host[found_host]['name']}... @ #{DateTime.now}"
      property_mappings = {}

      # To work around the VMFS 8-host limit (existed until ESX 5.0), as
      # well as just for organization purposes, we create one template per
      # cluster. This also provides us with additional isolation.
      vm_name = "#{host_properties_by_host[host]}-#{@cluster.name}"

      vm = nil
      wait_for_template = false
      # If the user sets opts[:run_without_interruptions], we will block
      # signals from the user (SIGINT, SIGTERM) in order to not be interrupted.
      # This is desirable, as other threads depend on this thread finishing
      # its prepare job and thus interrupting it has impacts beyond this
      # single thread or process.
      run_without_interruptions do
        begin
          vm =
            @connection.serviceContent.ovfManager.deployOVF(
              uri: ovf_url,
              vmName: vm_name,
              vmFolder: @folder,
              host: found_host,
              resourcePool: resource_pool,
              datastore: @datastore,
              networkMappings: network_mappings,
              propertyMappings: property_mappings,
            )
        rescue RbVmomi::Fault => fault
          # If two threads execute this script at the same time to upload
          # the same template under the same name, one will win and the other
          # with be rejected by VC. We catch those cases here, and handle
          # them by waiting for the winning thread to finish preparing the
          # template, see below ...
          is_duplicate = fault.fault.is_a?(RbVmomi::VIM::DuplicateName)
          is_duplicate ||= (fault.fault.is_a?(RbVmomi::VIM::InvalidState) &&
            !fault.fault.is_a?(RbVmomi::VIM::InvalidHostState))
          if is_duplicate
            wait_for_template = true
          else
            raise fault
          end
        end

        # The winning thread succeeded in uploading the OVF. Now we need to
        # prepare it for (linked) cloning and mark it as a template to signal
        # we are done.
        if !wait_for_template
          vm.add_delta_disk_layer_on_all_disks
          if opts[:config]
            # XXX: Should we add a version that does retries?
            vm.ReconfigVM_Task(spec: opts[:config]).wait_for_completion
          end
          vm.MarkAsTemplate
        end
      end

      # The losing thread now needs to wait for the winning thread to finish
      # uploading and preparing the template
      if wait_for_template
        puts "Template already exists, waiting for it to be ready @ #{DateTime.now}"
        vm = wait_for_template_ready(@folder, vm_name)
        puts "Template fully prepared and ready to be cloned @ #{DateTime.now}"
      end

      vm
    end

    # Creates a linked clone of a template prepared with upload_ovf_as_template.
    # The function waits for completion on the clone task. Optionally, in case
    # two level templates are being used, this function can wait for another
    # thread to finish creating the second level template. See class comments
    # for the concept of multi level templates.
    # @param template_name [String] Name of the template to be used. A cluster
    #                               specific post-fix will automatically be added.
    # @param vm_name [String] Name of the new VM that is being created via cloning.
    # @param config [Hash] VM Config delta to apply after the VM is cloned.
    #                      Allows the template to be customized, e.g. to adjust
    #                      CPU or Memory sizes or set annotations.
    # @option opts [int] :is_template If true, the clone is assumed to be a template
    #                                 again and collision and de-duping logic kicks
    #                                 in.
    # @return [VIM::VirtualMachine] The VIM::VirtualMachine instance of the clone
    def linked_clone(template_vm, vm_name, config, opts = {})
      spec = {
        location: {
          pool: resource_pool,
          datastore: @datastore,
          diskMoveType: :moveChildMostDiskBacking,
        },
        powerOn: false,
        template: false,
        config: config,
      }
      if opts[:is_template]
        wait_for_template = false
        template_name = "#{vm_name}-#{@cluster.name}"
        begin
          vm = template_vm.CloneVM_Task(
            folder: @folder,
            name: template_name,
            spec: spec
          ).wait_for_completion
        rescue RbVmomi::Fault => fault
          if fault.fault.is_a?(RbVmomi::VIM::DuplicateName)
            wait_for_template = true
          else
            raise
          end
        end

        if wait_for_template
          puts "#{Time.now}: Template already exists, waiting for it to be ready"
          vm = wait_for_template_ready @folder, template_name
          puts "#{Time.now}: Template ready"
        end
      else
        vm = template_vm.CloneVM_Task(
          folder: @folder,
          name: vm_name,
          spec: spec
        ).wait_for_completion
      end
      vm
    end

    private

    # Internal helper method that executes the passed in block while disabling
    # the handling of SIGINT and SIGTERM signals. Restores their handlers after
    # the block is executed.
    def run_without_interruptions
      int_handler = Signal.trap('SIGINT', 'IGNORE')
      term_handler = Signal.trap('SIGTERM', 'IGNORE')

      yield

      Signal.trap('SIGINT', int_handler)
      Signal.trap('SIGTERM', term_handler)
    end

    # Internal helper method that waits for a template to be fully created. It
    # polls until it finds the VM in the inventory, and once it is there, waits
    # for it to be fully created and marked as a template. This function will
    # block for forever if the template never gets created or marked as a
    # template.
    # @param vm_folder [VIM::Folder] Folder in which we expect the template to show up
    # @param vm_name [String] Name of the VM we are waiting for
    # @return [VIM::VirtualMachine] The VM we were waiting for when it is ready
    def wait_for_template_ready(vm_folder, vm_name)
      vm = nil
      while !vm
        sleep 3
        # XXX: Optimize this
        vm = vm_folder.children.find { |x| x.name == vm_name }
      end
      puts "Template VM found @ #{DateTime.now}"
      sleep 2
      loop do
        runtime, template = vm.collect 'runtime', 'config.template'
        ready = runtime && runtime.host && runtime.powerState == 'poweredOff'
        ready = ready && template
        if ready
          break
        end
        sleep 5
      end

      vm
    end
  end
end
