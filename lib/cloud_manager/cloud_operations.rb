###############################################################################
#    Copyright (c) 2012 VMware, Inc. All Rights Reserved.
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
################################################################################

# @since serengeti 0.5.0
# @version 0.5.0

module Serengeti
  module CloudManager
    class Cloud
      CLUSTER_ACTION_MESSAGE = {
        CLUSTER_DELETE => 'delete',
        CLUSTER_START  => 'start',
        CLUSTER_STOP   => 'stop',
      }

      def serengeti_vms_op(cloud_provider, cluster_info, cluster_data, action)
        act = CLUSTER_ACTION_MESSAGE[action]
        act = 'unknown' if act.nil?
        @logger.info("enter #{act} cluster ... ")
        create_cloud_provider(cloud_provider)
        result = prepare_working(cluster_info, cluster_data)
        dc_resources = result[:dc_res]

        @status = action
        matched_vms = dc_resources.clusters.values.map { |cs| cs.vms.values }.flatten
        matched_vms = matched_vms.select { |vm| vm_is_this_cluster?(vm.name) }

        #@logger.debug("operate vm list:#{matched_vms.pretty_inspect}")
        @logger.debug("vms name: #{matched_vms.collect{ |vm| vm.name }.pretty_inspect}")
        yield matched_vms

        @logger.debug("#{act} all vm's")
      end

      def list_vms(cloud_provider, cluster_info, cluster_data, task)
        action_process(CLOUD_WORK_LIST, task) do
          @logger.debug("enter list_vms...")
          create_cloud_provider(cloud_provider)
          prepare_working(cluster_info, cluster_data)
        end
        get_result.servers
      end

      def delete(cloud_provider, cluster_info, cluster_data, task)
        action_process(CLOUD_WORK_DELETE, task) do
          serengeti_vms_op(cloud_provider, cluster_info, cluster_data, CLUSTER_DELETE) do |vms|
            group_each_by_threads(vms, :callee=>'destory vm') { |vm| vm.delete }
          end
        end
      end

      def start(cloud_provider, cluster_info, cluster_data, task)
        action_process(CLOUD_WORK_START, task) do
          serengeti_vms_op(cloud_provider, cluster_info, cluster_data, CLUSTER_START) do |vms|
            vms.each { |vm| vm.action = VmInfo::VM_ACTION_START }
            cluster_wait_ready(vms)
          end
        end
      end

      def stop(cloud_provider, cluster_info, cluster_data, task)
        action_process(CLOUD_WORK_STOP, task) do
          serengeti_vms_op(cloud_provider, cluster_info, cluster_data, CLUSTER_STOP) do |vms|
            group_each_by_threads(vms, :callee=>'stop vm') { |vm| vm.stop }
          end
        end
      end

    end
  end
end
