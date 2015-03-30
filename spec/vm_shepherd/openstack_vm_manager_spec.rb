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
        network_name: 'Public',
        key_name: 'some-key',
        security_group_names: [
          'security-group-A',
          'security-group-B',
          'security-group-C',
        ],
        ip: '192.168.27.129',
      }
    end

    subject(:openstack_vm_manager) { OpenstackVmManager.new(openstack_options) }


    describe '#deploy' do
      let(:path) { 'path/to/qcow2/file' }
      let(:file_size) { 42 }

      let(:compute_service) do
        Fog::Compute.new(
          provider: 'openstack',
          openstack_auth_url: openstack_options[:auth_url],
          openstack_username: openstack_options[:username],
          openstack_tenant: openstack_options[:tenant],
          openstack_api_key: openstack_options[:api_key],
        )
      end
      let(:image_service) do
        Fog::Image.new(
          provider: 'openstack',
          openstack_auth_url: openstack_options[:auth_url],
          openstack_username: openstack_options[:username],
          openstack_tenant: openstack_options[:tenant],
          openstack_api_key: openstack_options[:api_key],
          openstack_endpoint_type: 'publicURL',
        )
      end
      let(:network_service) do
        Fog::Network.new(
          provider: 'openstack',
          openstack_auth_url: openstack_options[:auth_url],
          openstack_username: openstack_options[:username],
          openstack_tenant: openstack_options[:tenant],
          openstack_api_key: openstack_options[:api_key],
          openstack_endpoint_type: 'publicURL',
        )
      end

      let(:servers) { compute_service.servers }
      let(:addresses) { compute_service.addresses }
      let(:instance) { servers.find { |server| server.name == openstack_vm_options[:name] } }

      before do
        allow(File).to receive(:size).with(path).and_return(file_size)
        allow(subject).to receive(:say)

        Fog.mock!
        Fog::Mock.reset

        allow(Fog::Compute).to receive(:new).and_return(compute_service)
        allow(Fog::Image).to receive(:new).and_return(image_service)
        allow(Fog::Network).to receive(:new).and_return(network_service)

        allow(compute_service).to receive(:servers).and_return(servers)
        allow(compute_service).to receive(:addresses).and_return(addresses)
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

        openstack_vm_manager.deploy(path, openstack_vm_options)

        uploaded_image = image_service.images.find { |image| image.name == openstack_vm_options[:name] }
        expect(uploaded_image).to be
        expect(uploaded_image.size).to eq(file_size)
      end

      context 'when launching an instance' do
        it 'launches an image instance' do
          openstack_vm_manager.deploy(path, openstack_vm_options)

          expect(instance).to be
        end

        it 'uses the correct flavor for the instance' do
          openstack_vm_manager.deploy(path, openstack_vm_options)

          instance_flavor = compute_service.flavors.find { |flavor| flavor.id == instance.flavor['id'] }
          expect(instance_flavor.disk).to be >= 150
        end

        it 'uses the previously uploaded image' do
          openstack_vm_manager.deploy(path, openstack_vm_options)

          instance_image = image_service.images.get instance.image['id']
          expect(instance_image.name).to eq(openstack_vm_options[:name])
        end

        it 'assigns the correct key_name to the instance' do
          expect(servers).to receive(:create).with(
              hash_including(:key_name => openstack_vm_options[:key_name])
            ).and_call_original

          openstack_vm_manager.deploy(path, openstack_vm_options)
        end

        it 'assigns the correct security groups' do
          expect(servers).to receive(:create).with(
              hash_including(:security_groups => openstack_vm_options[:security_group_names])
            ).and_call_original

          openstack_vm_manager.deploy(path, openstack_vm_options)
        end

        it 'assigns the correct network id' do
          assigned_network = network_service.networks.find { |network| network.name == openstack_vm_options[:network_name] }
          expect(servers).to receive(:create).with(
              hash_including(:nics => [{ net_id: assigned_network.id }])
            ).and_call_original

          openstack_vm_manager.deploy(path, openstack_vm_options)
        end
      end

      it 'waits for the server to be ready' do
        openstack_vm_manager.deploy(path, openstack_vm_options)

        expect(instance.state).to eq('ACTIVE')
      end

      it 'assigns an IP to the instance' do
        openstack_vm_manager.deploy(path, openstack_vm_options)
        ip = addresses.find { |address| address.ip == openstack_vm_options[:ip] }

        expect(ip.instance_id).to eq(instance.id)
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

      let(:server) { double('Fog::Compute::OpenStack::Server', image: { 'id' => image.id }) }

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
