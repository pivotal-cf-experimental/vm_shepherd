require 'tempfile'
require 'vm_shepherd/ova_manager/deployer'

module VmShepherd
  module OvaManager
    RSpec.describe Deployer do
      let(:connection) { double('connection') }
      let(:cluster) { double('cluster', resourcePool: cluster_resource_pool) }
      let(:cluster_resource_pool) { double(:cluster_resource_pool, resourcePool: [a_resource_pool, another_resource_pool]) }

      let(:a_resource_pool) { double('resource_pool', name: 'resource_pool_name') }
      let(:another_resource_pool) { double('another_resource_pool', name: 'another_resource_pool_name') }

      let(:target_folder) { double('target_folder') }
      let(:datastore) { double('datastore') }
      let(:network) { double('network', name: 'network') }
      let(:datacenter) { double('datacenter', network: [network]) }
      let(:cached_ova_deployer) {
        double('CachedOvaDeployer', upload_ovf_as_template: template, linked_clone: linked_clone)
      }
      let(:template) { double('template', name: 'template name') }
      let(:ova_path) { File.join(SPEC_ROOT, 'fixtures', 'ova_manager', 'foo.ova') }
      let(:linked_clone) { double('linked clone', guest_ip: '1.1.1.1') }
      let(:vcenter_config) {
        {
          host: 'foo',
          user: 'bar',
          password: 'secret'
        }
      }

      subject(:deployer) { Deployer.new(vcenter_config, location) }

      before do
        allow(deployer).to receive(:system).with(/cd .* && tar xfv .*/).and_call_original
        allow(deployer).to receive(:system).with(/nc -z -w 5 .* 443/).and_return(false)

        allow(datacenter).to receive(:find_compute_resource).with('cluster').and_return(cluster)

        allow(datacenter).to receive(:find_datastore).with('datastore').and_return(datastore)

        allow(linked_clone).to receive_message_chain(:ReconfigVM_Task, :wait_for_completion)
        allow(linked_clone).to receive_message_chain(:PowerOnVM_Task, :wait_for_completion)

        allow(RbVmomi::VIM).to receive(:connect).with({
              host: vcenter_config[:host],
              user: vcenter_config[:user],
              password: vcenter_config[:password],
              ssl: true,
              insecure: true
            }).and_return connection

        allow(deployer).to receive(:find_datacenter).and_return(datacenter)

        allow(datacenter).to receive_message_chain(:vmFolder, :traverse).
            with('target_folder', RbVmomi::VIM::Folder, true).and_return(target_folder)
        allow(datacenter).to receive(:networkFolder).and_return(
            double(:networkFolder).tap do |network_folder|
              allow(network_folder).to receive(:traverse).with('network').and_return(network)
            end
          )
      end

      context 'resource pool is a parameter' do
        let(:location) {
          {
            connection: connection,
            network: 'network',
            cluster: 'cluster',
            folder: 'target_folder',
            datastore: 'datastore',
            datacenter: 'datacenter',
            resource_pool: resource_pool_name
          }
        }

        context 'resource pool can be found' do
          let(:resource_pool_name) { a_resource_pool.name }

          it 'uses VsphereClient::CachedOvfDeployer to deploy an OVA within a resource pool' do
            expect(VsphereClients::CachedOvfDeployer).to receive(:new).with(
                connection,
                network,
                cluster,
                a_resource_pool,
                target_folder,
                target_folder,
                datastore
              ).and_return(cached_ova_deployer)

            deployer.deploy('foo', ova_path, { ip: '1.1.1.1' })
          end
        end

        context 'resource pool cannot be found' do
          let(:resource_pool_name) { 'i am no body' }

          it 'uses VsphereClient::CachedOvfDeployer to deploy an OVA within a resource pool' do
            expect {
              deployer.deploy('foo', ova_path, { ip: '1.1.1.1' })
            }.to raise_error(/Failed to find resource pool '#{resource_pool_name}'/)
          end
        end
      end

      context 'when there is no resource pool in location' do
        let(:location) {
          {
            connection: connection,
            network: 'network',
            cluster: 'cluster',
            folder: 'target_folder',
            datastore: 'datastore',
            datacenter: 'datacenter',
          }
        }

        it 'uses the cluster resource pool' do
          expect(VsphereClients::CachedOvfDeployer).to receive(:new).with(
              connection,
              network,
              cluster,
              cluster_resource_pool,
              target_folder,
              target_folder,
              datastore
            ).and_return(cached_ova_deployer)

          deployer.deploy('foo', ova_path, { ip: '1.1.1.1' })
        end
      end
    end
  end
end
