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
        let(:deployer) { instance_double(VappManager::Deployer) }

        it 'uses VappManager::Deployer to launch a vm' do
          expect(VappManager::Deployer).to receive(:new).
              with(
                {
                  url: settings.vapp_deployer.creds.url,
                  organization: settings.vapp_deployer.creds.organization,
                  user: settings.vapp_deployer.creds.user,
                  password: settings.vapp_deployer.creds.password,
                },
                {
                  vdc: settings.vapp_deployer.vdc.name,
                  catalog: settings.vapp_deployer.vdc.catalog,
                  network: settings.vapp_deployer.vdc.network,
                },
                instance_of(Logger)
              ).and_return(deployer)

          expect(deployer).to receive(:deploy).with(
              'FAKE_PATH',
              {
                name: settings.vapp_deployer.vapp.name,
                ip: settings.vapp_deployer.vapp.ip,
                gateway: settings.vapp_deployer.vapp.gateway,
                netmask: settings.vapp_deployer.vapp.netmask,
                dns: settings.vapp_deployer.vapp.dns,
                ntp: settings.vapp_deployer.vapp.ntp,
              }
            )

          manager.deploy(path: 'FAKE_PATH')
        end
      end

      context 'with vsphere settings' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'vsphere.yml')))
        end
        let(:deployer) { instance_double(OvaManager::Deployer) }

        it 'uses OvaManager::Deployer to launch a vm' do
          expect(OvaManager::Deployer).to receive(:new).
              with(
                {
                  host: settings.vm_deployer.vcenter_creds.ip,
                  user: settings.vm_deployer.vcenter_creds.username,
                  password: settings.vm_deployer.vcenter_creds.password,
                },
                {
                  datacenter: settings.vm_deployer.vsphere.datacenter,
                  cluster: settings.vm_deployer.vsphere.cluster,
                  resource_pool: settings.vm_deployer.vsphere.resource_pool,
                  datastore: settings.vm_deployer.vsphere.datastore,
                  network: settings.vm_deployer.vsphere.network,
                  folder: settings.vm_deployer.vsphere.folder,
                },
              ).and_return(deployer)

          expect(deployer).to receive(:deploy).with(
              Shepherd::VSPHERE_TEMPLATE_PREFIX,
              'FAKE_PATH',
              {
                ip: settings.vm_deployer.vm.ip,
                gateway: settings.vm_deployer.vm.gateway,
                netmask: settings.vm_deployer.vm.netmask,
                dns: settings.vm_deployer.vm.dns,
                ntp_servers: settings.vm_deployer.vm.ntp_servers,
              }
            )

          manager.deploy(path: 'FAKE_PATH')
        end
      end

      context 'with AWS settings' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'aws.yml')))
        end
        let(:ams_manager) { instance_double(AmiManager) }
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

        it 'uses AwsManager::Deployer to launch a VM' do
          expect(AmiManager).to receive(:new).with(aws_options).and_return(ams_manager)
          expect(ams_manager).to receive(:deploy).with(ami_file_path)
          manager.deploy(path: ami_file_path)
        end
      end

      context 'with OpenStack settings' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'openstack.yml')))
        end
        let(:qcow2_manager) { instance_double(OpenstackVmManager) }
        let(:qcow2_file_path) { 'PATH_TO_QCOW2_FILE' }
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

        it 'uses QCow2Manager to launch a VM' do
          expect(OpenstackVmManager).to receive(:new).with(openstack_options).and_return(qcow2_manager)
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
        let(:destroyer) { instance_double(VappManager::Destroyer) }

        it 'uses VappManager::Destroyer to destroy a vm' do
          expect(VappManager::Destroyer).to receive(:new).with(
              {
                url: settings.vapp_deployer.creds.url,
                organization: settings.vapp_deployer.creds.organization,
                user: settings.vapp_deployer.creds.user,
                password: settings.vapp_deployer.creds.password,
              },
              {
                vdc: settings.vapp_deployer.vdc.name,
                catalog: settings.vapp_deployer.vdc.catalog,
              },
              instance_of(Logger)
            ).and_return(destroyer)
          expect(destroyer).to receive(:destroy).with(settings.vapp_deployer.vapp.name)

          manager.destroy
        end
      end

      context 'when IAAS is vsphere' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'vsphere.yml')))
        end
        let(:destroyer) { instance_double(OvaManager::Destroyer) }

        it 'uses OvaManager::Destroyer to destroy a vm' do
          expect(OvaManager::Destroyer).to receive(:new).with(
              settings.vm_deployer.vsphere.datacenter,
              {
                host: settings.vm_deployer.vcenter_creds.ip,
                user: settings.vm_deployer.vcenter_creds.username,
                password: settings.vm_deployer.vcenter_creds.password,
              }
            ).and_return(destroyer)
          expect(destroyer).to receive(:clean_folder).with(settings.vm_deployer.vsphere.folder)

          manager.destroy
        end
      end

      context 'when IAAS is AWS' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'aws.yml')))
        end
        let(:ams_manager) { instance_double(AmiManager) }
        let(:ami_destroy_options) do
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

        it 'uses AwsManager::Deployer to launch a VM' do
          expect(AmiManager).to receive(:new).with(ami_destroy_options).and_return(ams_manager)
          expect(ams_manager).to receive(:destroy)
          manager.destroy
        end
      end

      context 'when IAAS is Openstack' do
        let(:settings) do
          RecursiveOpenStruct.new(YAML.load_file(File.join(SPEC_ROOT, 'fixtures', 'shepherd', 'openstack.yml')))
        end
        let(:qcow2_manager) { instance_double(OpenstackVmManager) }
        let(:qcow2_file_path) { 'PATH_TO_QCOW2_FILE' }
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

        it 'uses QCow2Manager to destroy a VM' do
          expect(OpenstackVmManager).to receive(:new).with(openstack_options).and_return(qcow2_manager)
          expect(qcow2_manager).to receive(:destroy).with(openstack_vm_options)
          manager.destroy
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
  end
end
