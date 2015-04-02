require 'open-uri'
require 'nokogiri'
require 'rbvmomi'

module VsphereClients
  class CachedOvfDeployer
    attr_reader :resource_pool, :cluster

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

      puts "Uploading OVF to #{host_properties_by_host[found_host]['name']} @ #{DateTime.now}"

      vm =
        @connection.serviceContent.ovfManager.deployOVF(
          uri: ovf_url,
          vmName: "#{template_name}-#{@cluster.name}",
          vmFolder: @folder,
          host: found_host,
          resourcePool: resource_pool,
          datastore: @datastore,
          networkMappings: network_mappings,
          propertyMappings: {},
        )
      vm.add_delta_disk_layer_on_all_disks
      vm.MarkAsTemplate

      puts "Marked VM as Template @ #{DateTime.now}"

      vm
    end

    # Creates a linked clone of a template prepared with upload_ovf_as_template.
    # The function waits for completion on the clone task. Optionally, in case
    # two level templates are being used, this function can wait for another
    # thread to finish creating the second level template. See class comments
    # for the concept of multi level templates.
    # @param template_vm [String] Name of the template to be used. A cluster
    #                               specific post-fix will automatically be added.
    # @param vm_name [String] Name of the new VM that is being created via cloning.
    # @param config [Hash] VM Config delta to apply after the VM is cloned.
    #                      Allows the template to be customized, e.g. to adjust
    #                      CPU or Memory sizes or set annotations.
    # @option opts [int] :is_template If true, the clone is assumed to be a template
    #                                 again and collision and de-duping logic kicks
    #                                 in.
    # @return [VIM::VirtualMachine] The VIM::VirtualMachine instance of the clone
    def linked_clone(template_vm, vm_name, config)
      template_vm.CloneVM_Task(
        folder: @folder,
        name: vm_name,
        spec: {
          location: {
            pool: resource_pool,
            datastore: @datastore,
            diskMoveType: :moveChildMostDiskBacking,
          },
          powerOn: false,
          template: false,
          config: config,
        }
      ).wait_for_completion
    end
  end
end
