require 'vm_shepherd/openstack_vm_manager'

module VmShepherd
  RSpec.describe OpenstackVmManager do
    let(:openstack_options) do
      {
        auth_url: 'http://example.com',
        username: 'username',
        api_key: 'api-key',
        tenant: 'tenant',
      }
    end
    let(:openstack_vm_options) do
      {
        name: 'some-vm-name',
        min_disk_size: 150,
        network_name: 'some-network',
        key_name: 'some-key',
        security_group_names: [
          'security-group-A',
          'security-group-B',
          'security-group-C',
        ],
        ip: '198.11.195.5',
      }
    end

    subject(:openstack_vm_manager) { OpenstackVmManager.new(openstack_options) }


    describe '#deploy' do
      let(:service) { double('Fog::Compute', flavors: flavor_collection, addresses: ip_collection) }
      let(:server) { double('Fog::Compute::OpenStack::Server') }

      let(:ip_collection) { [ip] }
      let(:ip) do
        double('Fog::Compute::OpenStack::Address',
          instance_id: nil,
          ip: openstack_vm_options[:ip],
        )
      end

      let(:flavor_collection) { [flavor] }
      let(:flavor) { double('Fog::Compute::OpenStack::Flavor', id: 'flavor-id', disk: 150) }

      let(:image_service) { double('Fog::Image') }
      let(:image) { double('Fog::Image::OpenStack::Image', id: 'image-id') }

      let(:network_service) { double('Fog::Network', networks: network_collection) }
      let(:network_collection) { [network] }
      let(:network) do
        double('Fog::Compute::OpenStack::Network',
          name: openstack_vm_options[:network_name],
          id: 'network-id',
        )
      end

      let(:path) { 'path/to/qcow2/file' }
      let(:file_size) { 42 }

      before do
        allow(File).to receive(:size).with(path).and_return(file_size)

        allow(Fog::Compute).to receive(:new).and_return(service)
        allow(Fog::Image).to receive(:new).and_return(image_service)
        allow(Fog::Network).to receive(:new).and_return(network_service)
        allow(image_service).to receive_message_chain(:images, :create).and_return(image)
        allow(service).to receive_message_chain(:servers, :create).and_return(server)
        allow(server).to receive(:wait_for)
        allow(ip).to receive(:server=)
      end

      it 'creates a Fog::Compute connection' do
        expect(Fog::Compute).to receive(:new).with(
            {
              provider: 'openstack',
              openstack_auth_url: openstack_options[:auth_url],
              openstack_username: openstack_options[:username],
              openstack_tenant: openstack_options[:tenant],
              openstack_api_key: openstack_options[:api_key],
            }
          )
        openstack_vm_manager.deploy(path, openstack_vm_options)
      end

      it 'creates a Fog::Image connection' do
        expect(Fog::Image).to receive(:new).with(
            {
              provider: 'openstack',
              openstack_auth_url: openstack_options[:auth_url],
              openstack_username: openstack_options[:username],
              openstack_tenant: openstack_options[:tenant],
              openstack_api_key: openstack_options[:api_key],
              openstack_endpoint_type: 'publicURL',
            }
          )
        openstack_vm_manager.deploy(path, openstack_vm_options)
      end

      it 'creates a Fog::Network connection' do
        expect(Fog::Network).to receive(:new).with(
            {
              provider: 'openstack',
              openstack_auth_url: openstack_options[:auth_url],
              openstack_username: openstack_options[:username],
              openstack_tenant: openstack_options[:tenant],
              openstack_api_key: openstack_options[:api_key],
              openstack_endpoint_type: 'publicURL',
            }
          )
        openstack_vm_manager.deploy(path, openstack_vm_options)
      end

      it 'uploads the image' do
        file_size = 2
        expect(File).to receive(:size).with(path).and_return(file_size)

        expect(image_service).to receive_message_chain(:images, :create).with(
            name: openstack_vm_options[:name],
            size: file_size,
            disk_format: 'qcow2',
            container_format: 'bare',
            location: path,
          )

        openstack_vm_manager.deploy(path, openstack_vm_options)
      end

      it 'launches an image instance' do
        expect(service).to receive_message_chain(:servers, :create).with(
            :name => openstack_vm_options[:name],
            :flavor_ref => flavor.id,
            :image_ref => image.id,
            :key_name => openstack_vm_options[:key_name],
            :security_groups => openstack_vm_options[:security_group_names],
            :nics => [{net_id: network.id}]
          )
        openstack_vm_manager.deploy(path, openstack_vm_options)
      end

      it 'waits for the server to be ready' do
        expect(server).to receive(:wait_for)

        openstack_vm_manager.deploy(path, openstack_vm_options)
      end

      it 'assigns an IP to the instance' do
        expect(ip).to receive(:server=).with(server)
        openstack_vm_manager.deploy(path, openstack_vm_options)
      end
    end

    describe '#destroy' do
      let(:service) { double('Fog::Compute', addresses: ip_collection) }
      let(:ip_collection) { [ip] }
      let(:ip) do
        double('Fog::Compute::OpenStack::Address',
          instance_id: 'my-instance-id',
          ip: openstack_vm_options[:ip],
        )
      end

      let(:image_service) { double('Fog::Image') }
      let(:image) { double('Fog::Image::OpenStack::Image', id: 'image-id') }

      let(:server) { double('Fog::Compute::OpenStack::Server', image: {'id' => image.id} ) }

      before do
        allow(Fog::Compute).to receive(:new).and_return(service)
        allow(Fog::Image).to receive(:new).and_return(image_service)
        allow(image_service).to receive_message_chain(:images, :get).and_return(image)
        allow(service).to receive_message_chain(:servers, :get).and_return(server)
        allow(server).to receive(:destroy)
        allow(image).to receive(:destroy)
      end

      it 'creates a Fog::Compute connection' do
        expect(Fog::Compute).to receive(:new).with(
            {
              provider: 'openstack',
              openstack_auth_url: openstack_options[:auth_url],
              openstack_username: openstack_options[:username],
              openstack_tenant: openstack_options[:tenant],
              openstack_api_key: openstack_options[:api_key],
            }
          )
        openstack_vm_manager.destroy(openstack_vm_options)
      end

      it 'calls destroy on the correct instance' do
        expect(service).to receive_message_chain(:servers, :get).with(ip.instance_id)
        expect(server).to receive(:destroy)

        openstack_vm_manager.destroy(openstack_vm_options)
      end

      it 'calls destroy on the correct image' do
        expect(image_service).to receive_message_chain(:images, :get).with(image.id).and_return(image)
        expect(image).to receive(:destroy)

        openstack_vm_manager.destroy(openstack_vm_options)
      end
    end
  end
end
