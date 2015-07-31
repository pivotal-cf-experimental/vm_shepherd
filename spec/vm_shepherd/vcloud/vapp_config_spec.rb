require 'vm_shepherd/data_object'
require 'vm_shepherd/vcloud/vapp_config'

module VmShepherd
  module Vcloud
    RSpec.describe(VappConfig) do
      subject(:vapp_config) do
        VappConfig.new(
          name:    'NAME',
          ip:      'IP',
          gateway: 'GATEWAY',
          netmask: 'NETMASK',
          dns:     'DNS',
          ntp:     'NTP',
          catalog: 'CATALOG',
          network: 'NETWORK',
        )
      end

      it 'is a DataObject' do
        expect(vapp_config).to be_a(DataObject)
      end
    end
  end
end
