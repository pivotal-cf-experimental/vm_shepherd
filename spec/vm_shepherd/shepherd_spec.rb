require 'vm_shepherd'
require 'recursive_open_struct'

module VmShepherd
  RSpec.describe Shepherd do
    subject(:manager) { Shepherd.new(settings: settings) }
    let(:config) { settings.vm_shepherd_configs.first }
    let(:settings) do
      RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', settings_fixture_name)), recurse_over_arrays: true)
    end

    describe '#deploy' do
      context 'with vcloud settings' do
        let(:settings_fixture_name) { 'vcloud.yml' }
        let(:vcloud_manager) { instance_double(VcloudManager) }

        it 'uses VcloudManager to launch a vm' do
          expect(VcloudManager).to receive(:new).
              with(
                {
                  url: config.creds.url,
                  organization: config.creds.organization,
                  user: config.creds.user,
                  password: config.creds.password,
                },
                config.vdc.name,
                instance_of(Logger)
              ).and_return(vcloud_manager)

          expect(vcloud_manager).to receive(:deploy).with(
              'FAKE_PATH',
              {
                name: config.vapp.ops_manager_name,
                ip: config.vapp.ip,
                gateway: config.vapp.gateway,
                netmask: config.vapp.netmask,
                dns: config.vapp.dns,
                ntp: config.vapp.ntp,
                catalog: config.vdc.catalog,
                network: config.vdc.network,
              }
            )

          manager.deploy(path: 'FAKE_PATH')
        end
      end

      context 'with vsphere settings' do
        let(:settings_fixture_name) { 'vsphere.yml' }
        let(:ova_manager) { instance_double(VsphereManager) }

        it 'uses VsphereManager to launch a vm' do
          expect(VsphereManager).to receive(:new).with(
              config.vcenter_creds.ip,
                config.vcenter_creds.username,
                config.vcenter_creds.password,
                config.vsphere.datacenter,
              ).and_return(ova_manager)

          expect(ova_manager).to receive(:deploy).with(
              'FAKE_PATH',
              {
                ip: config.vm.ip,
                gateway: config.vm.gateway,
                netmask: config.vm.netmask,
                dns: config.vm.dns,
                ntp_servers: config.vm.ntp_servers,
              },
              {
                cluster: config.vsphere.cluster,
                resource_pool: config.vsphere.resource_pool,
                datastore: config.vsphere.datastore,
                network: config.vsphere.network,
                folder: config.vsphere.folder,
              },
            )

          manager.deploy(path: 'FAKE_PATH')
        end
      end

      context 'with AWS settings' do
        let(:settings_fixture_name) { 'aws.yml' }
        let(:ams_manager) { instance_double(AwsManager) }
        let(:ami_file_path) { 'PATH_TO_AMI_FILE' }
        let(:aws_options) do
          {
            aws_access_key: 'aws-access-key',
            aws_secret_key: 'aws-secret-key',
            ssh_key_name: 'ssh-key-name',
            security_group_id: 'security-group-id',
            public_subnet_id: 'public-subnet-id',
            private_subnet_id: 'private-subnet-id',
            elastic_ip_id: 'elastic-ip-id',
            vm_name: 'vm-name'
          }
        end

        it 'uses AwsManager to launch a VM' do
          expect(AwsManager).to receive(:new).with(aws_options).and_return(ams_manager)
          expect(ams_manager).to receive(:deploy).with(ami_file_path)
          manager.deploy(path: ami_file_path)
        end
      end

      context 'with OpenStack settings' do
        let(:settings_fixture_name) { 'openstack.yml' }
        let(:qcow2_manager) { instance_double(OpenstackManager) }
        let(:qcow2_file_path) { 'PATH_TO_QCOW2_FILE' }
        let(:openstack_options) do
          {
            auth_url: 'http://example.com/version/tokens',
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
            public_ip: '198.11.195.5',
            private_ip: '192.168.100.100',
          }
        end

        it 'uses OpenstackManager to launch a VM' do
          expect(OpenstackManager).to receive(:new).with(openstack_options).and_return(qcow2_manager)
          expect(qcow2_manager).to receive(:deploy).with(qcow2_file_path, openstack_vm_options)
          manager.deploy(path: qcow2_file_path)
        end
      end

      context 'when IAAS is unknown' do
        let(:settings_fixture_name) { 'unknown.yml' }

        it 'raises an exception' do
          expect { manager.deploy(path: 'FAKE_PATH') }.to raise_error(Shepherd::InvalidIaas)
        end
      end
    end

    describe '#destroy' do
      context 'when IAAS is vcloud' do
        let(:settings_fixture_name) { 'vcloud.yml' }
        let(:vcloud_manager) { instance_double(VcloudManager) }

        it 'uses VcloudManager to destroy a vm' do
          expect(VcloudManager).to receive(:new).with(
              {
                url: config.creds.url,
                organization: config.creds.organization,
                user: config.creds.user,
                password: config.creds.password,
              },
              config.vdc.name,
              instance_of(Logger)
            ).and_return(vcloud_manager)

          expect(vcloud_manager).to receive(:destroy).with(
              [config.vapp.ops_manager_name],
              config.vdc.catalog,
            )

          manager.destroy
        end
      end

      context 'when IAAS is vsphere' do
        let(:settings_fixture_name) { 'vsphere.yml' }
        let(:ova_manager) { instance_double(VsphereManager) }

        it 'uses VsphereManager to destroy a vm' do
          expect(VsphereManager).to receive(:new).with(
              config.vcenter_creds.ip,
              config.vcenter_creds.username,
              config.vcenter_creds.password,
              config.vsphere.datacenter,
            ).and_return(ova_manager)
          expect(ova_manager).to receive(:destroy).with(config.vm.ip, config.vsphere.resource_pool)

          manager.destroy
        end
      end

      context 'when IAAS is AWS' do
        let(:settings_fixture_name) { 'aws.yml' }
        let(:ams_manager) { instance_double(AwsManager) }
        let(:ami_options) do
          {
            aws_access_key: 'aws-access-key',
            aws_secret_key: 'aws-secret-key',
            ssh_key_name: 'ssh-key-name',
            security_group_id: 'security-group-id',
            public_subnet_id: 'public-subnet-id',
            private_subnet_id: 'private-subnet-id',
            elastic_ip_id: 'elastic-ip-id',
            vm_name: 'vm-name'
          }
        end

        it 'uses AwsManager to destroy a VM' do
          expect(AwsManager).to receive(:new).with(ami_options).and_return(ams_manager)
          expect(ams_manager).to receive(:destroy)
          manager.destroy
        end
      end

      context 'when IAAS is Openstack' do
        let(:settings_fixture_name) { 'openstack.yml' }
        let(:qcow2_manager) { instance_double(OpenstackManager) }
        let(:qcow2_file_path) { 'PATH_TO_QCOW2_FILE' }
        let(:openstack_options) do
          {
            auth_url: 'http://example.com/version/tokens',
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
            public_ip: '198.11.195.5',
            private_ip: '192.168.100.100',
          }
        end

        it 'uses OpenstackManager to destroy a VM' do
          expect(OpenstackManager).to receive(:new).with(openstack_options).and_return(qcow2_manager)
          expect(qcow2_manager).to receive(:destroy).with(openstack_vm_options)
          manager.destroy
        end
      end

      context 'when IAAS is unknown' do
        let(:settings_fixture_name) { 'unknown.yml' }

        it 'raises an exception' do
          expect { manager.destroy }.to raise_error(Shepherd::InvalidIaas)
        end
      end
    end

    describe '#clean_environment' do
      context 'when IAAS is vcloud' do
        let(:settings_fixture_name) { 'vcloud.yml' }
        let(:vcloud_manager) { instance_double(VcloudManager) }

        it 'uses VcloudManager to destroy a vm' do
          expect(VcloudManager).to receive(:new).with(
              {
                url: config.creds.url,
                organization: config.creds.organization,
                user: config.creds.user,
                password: config.creds.password,
              },
              config.vdc.name,
              instance_of(Logger)
            ).and_return(vcloud_manager)

          expect(vcloud_manager).to receive(:clean_environment).with(
              config.vapp.product_names,
              config.vapp.product_catalog,
            )

          manager.clean_environment
        end
      end

      context 'when IAAS is vsphere' do
        let(:settings_fixture_name) { 'vsphere.yml' }
        let(:ova_manager) { instance_double(VsphereManager) }
        let(:clean_environment_options) do
          {
            datacenter_folders_to_clean: config.cleanup.datacenter_folders_to_clean,
            datastores: config.cleanup.datastores,
            datastore_folders_to_clean: config.cleanup.datastore_folders_to_clean,
          }
        end

        it 'uses VsphereManager to destroy a vm' do
          expect(VsphereManager).to receive(:new).with(
              config.vcenter_creds.ip,
              config.vcenter_creds.username,
              config.vcenter_creds.password,
              config.cleanup.datacenter,
            ).and_return(ova_manager)
          expect(ova_manager).to receive(:clean_environment).with(clean_environment_options)

          manager.clean_environment
        end
      end

      context 'when IAAS is AWS' do
        let(:settings_fixture_name) { 'aws.yml' }
        let(:ams_manager) { instance_double(AwsManager) }
        let(:ami_options) do
          {
            aws_access_key: 'aws-access-key',
            aws_secret_key: 'aws-secret-key',
            ssh_key_name: 'ssh-key-name',
            security_group_id: 'security-group-id',
            public_subnet_id: 'public-subnet-id',
            private_subnet_id: 'private-subnet-id',
            elastic_ip_id: 'elastic-ip-id',
            vm_name: 'vm-name'
          }
        end

        it 'uses AwsManager to destroy a VM' do
          expect(AwsManager).to receive(:new).with(ami_options).and_return(ams_manager)
          expect(ams_manager).to receive(:clean_environment)
          manager.clean_environment
        end
      end

      context 'when IAAS is Openstack' do
        let(:settings_fixture_name) { 'openstack.yml' }
        let(:qcow2_manager) { instance_double(OpenstackManager) }
        let(:qcow2_file_path) { 'PATH_TO_QCOW2_FILE' }
        let(:openstack_options) do
          {
            auth_url: 'http://example.com/version/tokens',
            username: 'username',
            api_key: 'api-key',
            tenant: 'tenant',
          }
        end

        it 'uses OpenstackManager to destroy a VM' do
          expect(OpenstackManager).to receive(:new).with(openstack_options).and_return(qcow2_manager)
          expect(qcow2_manager).to receive(:clean_environment)
          manager.clean_environment
        end
      end

      context 'when IAAS is unknown' do
        let(:settings_fixture_name) { 'unknown.yml' }

        it 'raises an exception' do
          expect { manager.clean_environment }.to raise_error(Shepherd::InvalidIaas)
        end
      end
    end
  end
end
