require 'vm_shepherd/shepherd'
require 'vm_shepherd/vapp_manager/deployer'
require 'vm_shepherd/vapp_manager/destroyer'
require 'vm_shepherd/ova_manager/deployer'
require 'vm_shepherd/ova_manager/destroyer'
require 'vm_shepherd/ami_manager'
require 'vm_shepherd/openstack_vm_manager'

module VmShepherd
  AWS_IAAS_TYPE = 'aws'.freeze
  OPENSTACK_IAAS_TYPE = 'openstack'.freeze
  VCLOUD_IAAS_TYPE = 'vcloud'.freeze
  VSPHERE_IAAS_TYPE = 'vsphere'.freeze
end
