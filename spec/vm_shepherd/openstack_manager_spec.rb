require 'vm_shepherd/openstack_manager'
require 'support/patched_fog'

module VmShepherd
  RSpec.describe OpenstackManager do
    include PatchedFog

    let(:tenant_name) { 'tenant' }
    let(:openstack_options) do
      {
        auth_url: 'http://example.com/version/tokens',
        username: 'username',
        api_key: 'api-key',
        tenant: tenant_name,
      }
    end
    let(:openstack_vm_options) do
      {
        name: 'some-vm-name',
        flavor_name: 'some-flavor',
        network_name: 'Public',
        key_name: 'some-key',
        security_group_names: [
          'security-group-A',
          'security-group-B',
          'security-group-C',
        ],
        public_ip: '192.168.27.129', #magik ip to Fog::Mock
        private_ip: '192.168.27.100',
      }
    end

    subject(:openstack_vm_manager) { OpenstackManager.new(openstack_options) }

    describe '#service' do
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
        openstack_vm_manager.service
      end
    end

    describe '#image_service' do
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
        openstack_vm_manager.image_service
      end
    end

    describe '#network_service' do
      it 'creates a Fog::Network connection' do
        expect(Fog::Network).to receive(:new).with(
            {
              provider: 'openstack',
              openstack_auth_url: openstack_options[:auth_url],
              openstack_username: openstack_options[:username],
              openstack_tenant: openstack_options[:tenant],
              openstack_api_key: openstack_options[:api_key],
            }
          )
        openstack_vm_manager.network_service
      end
    end

    describe '#deploy' do
      let(:path) { 'path/to/raw/file' }
      let(:file_size) { 42 }

      let(:compute_service) { openstack_vm_manager.service }
      let(:image_service) { openstack_vm_manager.image_service }
      let(:network_service) { openstack_vm_manager.network_service }

      let(:flavors) { compute_service.flavors }
      let(:servers) { compute_service.servers }
      let(:addresses) { compute_service.addresses }
      let(:instance) { servers.find { |server| server.name == openstack_vm_options[:name] } }

      before do
        allow(File).to receive(:size).with(path).and_return(file_size)
        allow(openstack_vm_manager).to receive(:say)

        Fog.mock!
        Fog::Mock.reset
        Fog::Mock.delay = 0

        allow(compute_service).to receive(:servers).and_return(servers)
        allow(compute_service).to receive(:flavors).and_return(flavors)
        allow(compute_service).to receive(:addresses).and_return(addresses)

        flavors << flavors.create(name: 'some-flavor', ram: 1, vcpus: 1, disk: 1)
      end

      it 'uploads the image' do
        file_size = 2
        expect(File).to receive(:size).with(path).and_return(file_size)

        openstack_vm_manager.deploy(path, openstack_vm_options)

        uploaded_image = image_service.images.find { |image| image.name == openstack_vm_options[:name] }
        expect(uploaded_image).to be
        expect(uploaded_image.size).to eq(file_size)
        expect(uploaded_image.disk_format).to eq('raw')
      end

      context 'when launching an instance' do
        it 'launches an image instance' do
          openstack_vm_manager.deploy(path, openstack_vm_options)

          expect(instance).to be
        end

        it 'uses the correct flavor for the instance' do

          openstack_vm_manager.deploy(path, openstack_vm_options)

          instance_flavor = compute_service.flavors.find { |flavor| flavor.id == instance.flavor['id'] }
          expect(instance_flavor.name).to eq('some-flavor')
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

        it 'assigns the correct private network information' do
          assigned_network = network_service.networks.find { |network| network.name == openstack_vm_options[:network_name] }
          expect(servers).to receive(:create).with(
              hash_including(:nics => [
                  {net_id: assigned_network.id, v4_fixed_ip: openstack_vm_options[:private_ip]}
                ]
              )
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
        ip = addresses.find { |address| address.ip == openstack_vm_options[:public_ip] }

        expect(ip.instance_id).to eq(instance.id)
      end
    end

    describe '#destroy' do
      let(:path) { 'path/to/raw/file' }
      let(:file_size) { 42 }

      let(:compute_service) { openstack_vm_manager.service }
      let(:image_service) { openstack_vm_manager.image_service }

      let(:servers) { compute_service.servers }
      let(:flavors) { compute_service.flavors }
      let(:images) { image_service.images }
      let(:image) { images.find { |image| image.name == openstack_vm_options[:name] } }
      let(:instance) { servers.find { |server| server.name == openstack_vm_options[:name] } }

      before do
        allow(File).to receive(:size).with(path).and_return(file_size)
        allow(openstack_vm_manager).to receive(:say)

        Fog.mock!
        Fog::Mock.reset
        Fog::Mock.delay = 0

        allow(compute_service).to receive(:flavors).and_return(flavors)
        allow(compute_service).to receive(:servers).and_return(servers)
        allow(image_service).to receive(:images).and_return(images)

        flavors << flavors.create(name: 'some-flavor', ram: 1, vcpus: 1, disk: 1)
        openstack_vm_manager.deploy(path, openstack_vm_options)
      end

      def destroy_correct_image
        change do
          images.reload
          images.select { |image| image.name == openstack_vm_options[:name] }.any?
        end.from(true).to(false)
      end

      it 'calls destroy on the correct instance' do
        destroy_correct_server = change do
          servers.reload
          servers.find { |server| server.name == openstack_vm_options[:name] }
        end.to(nil)

        expect { openstack_vm_manager.destroy(openstack_vm_options) }.to(destroy_correct_server)
      end

      it 'calls destroy on the correct image' do
        expect { openstack_vm_manager.destroy(openstack_vm_options) }.to(destroy_correct_image)
      end

      context 'when the server does not exist' do
        before do
          allow(servers).to receive(:find).and_return(nil)
        end

        it 'returns without error' do
          expect { openstack_vm_manager.destroy(openstack_vm_options) }.not_to raise_error
        end

        it 'calls destroy on the correct image' do
          expect { openstack_vm_manager.destroy(openstack_vm_options) }.to(destroy_correct_image)
        end
      end
    end

    describe '#clean_environment' do
      before do
        allow(openstack_vm_manager).to receive(:say)

        Fog.mock!
        Fog::Mock.reset
        Fog::Mock.delay = 0
        Fog.interval = 0

        make_server_and_image!('vm1')
        make_server_and_image!('vm2')
        openstack_vm_manager.image_service.images.create(
          name: 'public',
          size: 13784321,
          disk_format: 'raw',
          container_format: 'bare',
          location: '/tmp/notreal',
          is_public: true,
        )

        openstack_vm_manager.storage_service.directories
        a_dir = instance_double(Fog::Storage::OpenStack::Directory, key: 'a_dir')
        allow(a_dir).to receive(:files).and_return(a_dir_files)
        b_dir = instance_double(Fog::Storage::OpenStack::Directory, key: 'b_dir')
        allow(b_dir).to receive(:files).and_return(b_dir_files)
        allow(openstack_vm_manager.storage_service).to receive(:directories).and_return([a_dir, b_dir])
        allow_any_instance_of(Fog::Compute::OpenStack::Volume).to receive(:status).and_return('available')
        allow(Fog).to receive(:sleep)
      end

      let(:a_dir_files) { [create_file_double('a_file'), create_file_double('b_file')] }
      let(:b_dir_files) { [create_file_double('c_file'), create_file_double('d_file')] }

      def create_file_double(key)
        instance_double(Fog::Storage::OpenStack::File, destroy: nil, key: key)
      end

      def make_server_and_image!(name)
        image = openstack_vm_manager.image_service.images.create(
          name: name,
          size: 13784321,
          disk_format: 'raw',
          container_format: 'bare',
          location: '/tmp/notreal',
          is_public: false,
        )

        server = openstack_vm_manager.service.servers.create(
          name: name,
          flavor_ref: openstack_vm_manager.service.flavors.first.id,
          image_ref: image.id,
          key_name: 'some key',
          security_groups: ['some security group'],
        )

        volume = openstack_vm_manager.service.volumes.create(
          name: name,
          description: "description #{name}",
          size: name.to_i,
        )
        server.attach_volume(volume.id, 'xd1')
      end

      it 'deletes all servers and server-volume attachments' do
        openstack_vm_manager.service.servers.each do |server|
          server.volumes.each do |volume|
            expect(openstack_vm_manager.service).to receive(:detach_volume).with(server.id, volume.id).ordered
          end
          expect(openstack_vm_manager.service).to receive(:delete_server).with(server.id).ordered.and_call_original
        end

        expect {
          openstack_vm_manager.clean_environment
        }.to change { openstack_vm_manager.service.servers.size }.from(2).to(0)
      end

      it 'waits until there are no servers before deleting images' do
        stub_const("VmShepherd::RetryHelper::RETRY_INTERVAL", 0)

        servers = instance_double(Array)
        allow(openstack_vm_manager.service).to receive(:servers).and_return(servers)

        allow(servers).to receive(:size)
        allow(servers).to receive(:each).and_return([])
        expect(servers).to receive(:count).and_return(1,0).ordered
        expect(openstack_vm_manager.image_service).to receive(:images).and_return([]).ordered

        openstack_vm_manager.clean_environment
      end

      it 'deletes all private images' do
        expect {
          openstack_vm_manager.clean_environment
        }.to change { openstack_vm_manager.image_service.images.size }.from(3).to(1)
      end

      it 'deletes all volumes' do
        expect {
          openstack_vm_manager.clean_environment
        }.to change { openstack_vm_manager.service.volumes.size }.from(2).to(0)
      end

      context 'with stubbed volumes' do
        let(:volumes) { [volume] }
        let(:volume) do
          openstack_vm_manager.service.volumes.create(
            name: 'volume',
            description: 'description',
            size: 1,
          )
        end

        before do
          allow(openstack_vm_manager.service).to receive(:volumes).and_return(volumes)
        end

        it 'waits for volumes to be available before deleting' do
          expect(volume).to receive(:status).and_return('detaching', 'detaching', 'available')
          openstack_vm_manager.clean_environment
        end
      end

      it 'deletes everything in the correct container' do
        openstack_vm_manager.clean_environment
        expect(a_dir_files[0]).to have_received(:destroy)
        expect(a_dir_files[1]).to have_received(:destroy)
        expect(b_dir_files[0]).to have_received(:destroy)
        expect(b_dir_files[1]).to have_received(:destroy)
      end
    end
  end
end
