require 'vm_shepherd'
require 'recursive_open_struct'

module VmShepherd
  RSpec.describe Shepherd do
    subject(:manager) { Shepherd.new(settings: settings) }

    describe '#deploy' do
      context 'with vcloud settings' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'vcloud.yml')))
        end
        let(:vcloud_manager) { instance_double(VcloudManager) }

        it 'uses VcloudManager to launch a vm' do
          expect(VcloudManager).to receive(:new).
              with(
                {
                  url: settings.vm_shepherd.creds.url,
                  organization: settings.vm_shepherd.creds.organization,
                  user: settings.vm_shepherd.creds.user,
                  password: settings.vm_shepherd.creds.password,
                },
                settings.vm_shepherd.vdc.name,
                instance_of(Logger)
              ).and_return(vcloud_manager)

          expect(vcloud_manager).to receive(:deploy).with(
              'FAKE_PATH',
              {
                name: settings.vm_shepherd.vapp.ops_manager_name,
                ip: settings.vm_shepherd.vapp.ip,
                gateway: settings.vm_shepherd.vapp.gateway,
                netmask: settings.vm_shepherd.vapp.netmask,
                dns: settings.vm_shepherd.vapp.dns,
                ntp: settings.vm_shepherd.vapp.ntp,
                catalog: settings.vm_shepherd.vdc.catalog,
                network: settings.vm_shepherd.vdc.network,
              }
            )

          manager.deploy(path: 'FAKE_PATH')
        end
      end

      context 'with vsphere settings' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'vsphere.yml')))
        end
        let(:ova_manager) { instance_double(VsphereManager) }

        it 'uses VsphereManager to launch a vm' do
          expect(VsphereManager).to receive(:new).with(
              settings.vm_shepherd.vcenter_creds.ip,
                settings.vm_shepherd.vcenter_creds.username,
                settings.vm_shepherd.vcenter_creds.password,
                settings.vm_shepherd.vsphere.datacenter,
              ).and_return(ova_manager)

          expect(ova_manager).to receive(:deploy).with(
              'FAKE_PATH',
              {
                ip: settings.vm_shepherd.vm.ip,
                gateway: settings.vm_shepherd.vm.gateway,
                netmask: settings.vm_shepherd.vm.netmask,
                dns: settings.vm_shepherd.vm.dns,
                ntp_servers: settings.vm_shepherd.vm.ntp_servers,
              },
              {
                cluster: settings.vm_shepherd.vsphere.cluster,
                resource_pool: settings.vm_shepherd.vsphere.resource_pool,
                datastore: settings.vm_shepherd.vsphere.datastore,
                network: settings.vm_shepherd.vsphere.network,
                folder: settings.vm_shepherd.vsphere.folder,
              },
            )

          manager.deploy(path: 'FAKE_PATH')
        end
      end

      context 'with AWS settings' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'aws.yml')))
        end
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
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'openstack.yml')))
        end
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
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'unknown.yml')))
        end

        it 'raises an exception' do
          expect { manager.deploy(path: 'FAKE_PATH') }.to raise_error(Shepherd::InvalidIaas)
        end
      end
    end

    describe '#destroy' do
      context 'when IAAS is vcloud' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'vcloud.yml')))
        end
        let(:vcloud_manager) { instance_double(VcloudManager) }

        it 'uses VcloudManager to destroy a vm' do
          expect(VcloudManager).to receive(:new).with(
              {
                url: settings.vm_shepherd.creds.url,
                organization: settings.vm_shepherd.creds.organization,
                user: settings.vm_shepherd.creds.user,
                password: settings.vm_shepherd.creds.password,
              },
              settings.vm_shepherd.vdc.name,
              instance_of(Logger)
            ).and_return(vcloud_manager)

          expect(vcloud_manager).to receive(:destroy).with(
              [settings.vm_shepherd.vapp.ops_manager_name],
              settings.vm_shepherd.vdc.catalog,
            )

          manager.destroy
        end
      end

      context 'when IAAS is vsphere' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'vsphere.yml')))
        end
        let(:ova_manager) { instance_double(VsphereManager) }

        it 'uses VsphereManager to destroy a vm' do
          expect(VsphereManager).to receive(:new).with(
              settings.vm_shepherd.vcenter_creds.ip,
              settings.vm_shepherd.vcenter_creds.username,
              settings.vm_shepherd.vcenter_creds.password,
              settings.vm_shepherd.vsphere.datacenter,
            ).and_return(ova_manager)
          expect(ova_manager).to receive(:destroy).with(settings.vm_shepherd.vm.ip, settings.vm_shepherd.vsphere.resource_pool)

          manager.destroy
        end
      end

      context 'when IAAS is AWS' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'aws.yml')))
        end
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
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'openstack.yml')))
        end
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
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'unknown.yml')))
        end

        it 'raises an exception' do
          expect { manager.destroy }.to raise_error(Shepherd::InvalidIaas)
        end
      end
    end

    describe '#clean_environment' do
      context 'when IAAS is vcloud' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'vcloud.yml')))
        end
        let(:vcloud_manager) { instance_double(VcloudManager) }

        it 'uses VcloudManager to destroy a vm' do
          expect(VcloudManager).to receive(:new).with(
              {
                url: settings.vm_shepherd.creds.url,
                organization: settings.vm_shepherd.creds.organization,
                user: settings.vm_shepherd.creds.user,
                password: settings.vm_shepherd.creds.password,
              },
              settings.vm_shepherd.vdc.name,
              instance_of(Logger)
            ).and_return(vcloud_manager)

          expect(vcloud_manager).to receive(:clean_environment).with(
              settings.vm_shepherd.vapp.product_names,
              settings.vm_shepherd.vapp.product_catalog,
            )

          manager.clean_environment
        end
      end

      context 'when IAAS is vsphere' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'vsphere.yml')))
        end
        let(:ova_manager) { instance_double(VsphereManager) }
        let(:clean_environment_options) do
          {
            datacenter_folders_to_clean: settings.vm_shepherd.cleanup.datacenter_folders_to_clean,
            datastores: settings.vm_shepherd.cleanup.datastores,
            datastore_folders_to_clean: settings.vm_shepherd.cleanup.datastore_folders_to_clean,
          }
        end

        it 'uses VsphereManager to destroy a vm' do
          expect(VsphereManager).to receive(:new).with(
              settings.vm_shepherd.vcenter_creds.ip,
              settings.vm_shepherd.vcenter_creds.username,
              settings.vm_shepherd.vcenter_creds.password,
              settings.vm_shepherd.cleanup.datacenter,
            ).and_return(ova_manager)
          expect(ova_manager).to receive(:clean_environment).with(clean_environment_options)

          manager.clean_environment
        end
      end

      context 'when IAAS is AWS' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'aws.yml')))
        end
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
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'openstack.yml')))
        end
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
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'unknown.yml')))
        end

        it 'raises an exception' do
          expect { manager.clean_environment }.to raise_error(Shepherd::InvalidIaas)
        end
      end
    end
  end
end
