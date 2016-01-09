require 'vm_shepherd/shepherd'
require 'vm_shepherd/data_object'
require 'vm_shepherd/aws_manager'
require 'vm_shepherd/openstack_manager'
require 'vm_shepherd/vcloud_manager'
require 'vm_shepherd/vcloud/deployer'
require 'vm_shepherd/vcloud/destroyer'
require 'vm_shepherd/vcloud/vapp_config'
require 'vm_shepherd/vsphere_manager'
require 'backport_refinements'

module VmShepherd
  AWS_IAAS_TYPE       = 'aws'.freeze
  OPENSTACK_IAAS_TYPE = 'openstack'.freeze
  VCLOUD_IAAS_TYPE    = 'vcloud'.freeze
  VSPHERE_IAAS_TYPE   = 'vsphere'.freeze
end
