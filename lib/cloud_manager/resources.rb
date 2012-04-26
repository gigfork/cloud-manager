module VHelper::CloudManager
  class Resources
    class Datacenter
      attr_accessor :mob
      attr_accessor :name
      attr_accessor :clusters
      attr_accessor :racks
      attr_accessor :share_datastore_pattern
      attr_accessor :local_datastore_pattern
      attr_accessor :allow_mixed_datastores
      attr_accessor :spec
      def inspect
        "<Datacenter: #{@mob} / #{@name}>"
      end
    end

    class Datastore
      attr_accessor :mob
      attr_accessor :name
      attr_accessor :type
      attr_accessor :total_space
      attr_accessor :free_space
      attr_accessor :unaccounted_space

      def real_free_space
        @free_space - @unaccounted_space
      end

      def inspect
        "<Datastore: #{@mob} / #{@name} size(#{@real_free_space} / #{@free_space} / #{@total_space}>\n"
      end
    end

    def is_vc_req_rp?(resource_pool, vc_req)
      return false if resource_pool.nil?
      return true if vc_req['vc_rps'].nil?
      vc_req['vc_rps'].each {|rp_name| return true if rp_name.eql?(resource_pool.name)}
      false
    end

    def is_vc_req_ds?(datastore, vc_req)
      true
    end

    class Cluster
      attr_accessor :mob
      attr_accessor :name
      attr_accessor :datacenter
      attr_accessor :resource_pools
      attr_accessor :hosts
      attr_accessor :share_datastores
      attr_accessor :local_datastores
      attr_accessor :idle_cpu
      attr_accessor :total_memory
      attr_accessor :free_memory
      attr_accessor :unaccounted_memory
      attr_accessor :mem_over_commit
      attr_accessor :vms
      attr_accessor :share_datastore_pattern
      attr_accessor :local_datastore_pattern
      attr_reader   :vc_req

      def real_free_memory
        @free_memory - @unaccounted_memory * @mem_over_commit
      end

      def inspect
        "<Cluster: #{@mob} / #{@name}>"
      end
    end

    class ResourcePool
      attr_accessor :mob
      attr_accessor :name
      attr_accessor :shares
      attr_accessor :host_used_mem
      attr_accessor :guest_used_mem
      attr_accessor :limit_mem#MB
      attr_accessor :free_memory
      attr_accessor :unaccounted_memory
      attr_accessor :config_mem
      attr_accessor :cluster
      attr_accessor :rev_used_mem
      def real_free_memory
        @free_memory - @unaccounted_memory
      end
      def inspect
        "<Resource Pool: #{@mob} / #{@name}, #{@real_free_memory}MB limit:#{@limit_mem}MB in #{@cluster.inspect}>"
      end
    end

    class Host
      attr_accessor :mob
      attr_accessor :name

      attr_accessor :datacenter         # this host belongs to which datacenter
      attr_accessor :cluster            # this host belongs to which cluster
      attr_accessor :resource_pool      # this host belongs to which resource_pool
      attr_accessor :rack_name          # rack name
      attr_accessor :share_datastores
      attr_accessor :local_datastores
      attr_accessor :cpu_limit          #MHZ
      attr_accessor :idle_cpu           # %
      attr_accessor :total_memory       #MB
      attr_accessor :free_memory
      attr_accessor :unaccounted_memory
      attr_accessor :mem_over_commit
      attr_accessor :datastores         #
      attr_accessor :vms                # all vms belongs to this host
      attr_accessor :used_mem
      attr_accessor :used_cpu
      attr_accessor :connection_state
      attr_accessor :place_share_datastores
      attr_accessor :place_local_datastores

      def real_free_memory
        (@free_memory - @unaccounted_memory) 
      end

      def inspect
        msg = "<Host: #{@mob} / #{@name}, #{@real_free_memory}/#{@free_memory}/#{@total_memory}>, vm #{@vms.size}\n datastores:\n"
        share_datastores.each_value {|datastore|msg<<"share "<<datastore.inspect}
        local_datastores.each_value {|datastore|msg<<"local "<<datastore.inspect}
        msg
      end
    end

    #########################################################
    # Begin Resource functions
    def initialize(client, vhelper, mem_over_commit = 1.0)
      @client           = client
      @vhelper          = vhelper
      @datacenter       = {}
      @lock             = Mutex.new
      @logger           = client.logger
      @mem_over_commit  = mem_over_commit
    end

    def fetch_datacenter(datacenter_name)
      datacenter_mob = @client.get_dc_mob_ref_by_path(datacenter_name)
      if datacenter_mob.nil?
        @logger.debug("Do not find the datacenter: #{datacenter_name}")
        raise "Do not find the datacenter: #{datacenter_name}"
      end
      attr = @client.ct_mob_ref_to_attr_hash(datacenter_mob, "DC")

      datacenter                      = Datacenter.new
      datacenter.mob                  = attr[:mo_ref]
      datacenter.name                 = datacenter_name

      @logger.debug("Found datacenter: #{datacenter.name} @ #{datacenter.mob}")

      raise "Missing share_datastore_pattern in director config" if @vhelper.vc_share_datastore_pattern.nil?
      datacenter.share_datastore_pattern    = @vhelper.vc_share_datastore_pattern
      datacenter.local_datastore_pattern = @vhelper.vc_local_datastore_pattern

      datacenter.allow_mixed_datastores = @vhelper.allow_mixed_datastores
      datacenter.racks = @vhelper.racks

      datacenter.clusters = fetch_clusters(datacenter, datacenter_mob)
      datacenter
    end

    def fetch_clusters(datacenter, datacenter_mob)
      cluster_mobs = @client.get_clusters_by_dc_mob(datacenter_mob)

      cluster_names = @vhelper.vc_req_rps.keys
      clusters_req = @vhelper.vc_req_rps 

      clusters = {}
      cluster_mobs.each do |cluster_mob|
        attr = @client.ct_mob_ref_to_attr_hash(cluster_mob, "CS")
        # chose cluster in cluster_names
        next unless clusters_req.key?(attr["name"])

        @logger.debug("Use cluster :#{attr["name"]} and checking resource pools")
        resource_pools = fetch_resource_pool(cluster_mob, clusters_req[attr["name"]])
        if resource_pools.empty?
          @logger.debug("Do not find any reqired resources #{clusters_req[attr["name"]]} in cluster :#{attr["name"]}")
          next
        end

        cluster                     = Cluster.new
        cluster.mem_over_commit     = @mem_over_commit
        cluster.mob                 = attr["mo_ref"]
        cluster.name                = attr["name"]
        cluster.vms                 = {}
        cluster.share_datastore_pattern = @vhelper.input_cluster_info["vc_shared_datastore_pattern"] || datacenter.share_datastore_pattern
        cluster.local_datastore_pattern = @vhelper.input_cluster_info["vc_local_datastore_pattern"] || datacenter.local_datastore_pattern
 
        @logger.debug("Found cluster: #{cluster.name} @ #{cluster.mob}")

        cluster.resource_pools      = resource_pools
        cluster.datacenter          = datacenter
        cluster.share_datastores    = fetch_datastores(@client.get_datastores_by_cs_mob(cluster_mob),
                                                       datacenter.share_datastore_pattern)
        @logger.debug("warning: no matched sharestores in cluster:#{cluster.name}") if cluster.share_datastores.empty?

        cluster.local_datastores    = fetch_datastores(@client.get_datastores_by_cs_mob(cluster_mob),
                                                       datacenter.local_datastore_pattern)
        @logger.debug("warning: no matched sharestores in cluster:#{cluster.name}") if cluster.share_datastores.empty?

        # make sure share_datastores and local_datastores are mutually exclusive
        #share_datastore_names = cluster.share_datastores.map { |ds| ds.name }
        #local_datastore_names = cluster.local_datastores.map { |ds| ds.name }

        #if (share_datastore_names & local_datastore_names).length != 0 && !datacenter.allow_mixed_datastores
        #  raise("datastore patterns are not mutually exclusive non-persistent are #{share_datastore_names.pretty_inspect}\n " +
        #        "local are: #{local_datastore_names.pretty_inspect} \n , " +
        #  "please use allow_mixed_datastores director configuration parameter to allow this")
        #end
        #@logger.debug("share datastores are #{cluster.share_datastores} " +
        #              "local datastores are #{cluster.local_datastores}")

        cluster.hosts = fetch_hosts(cluster, cluster_mob)

        clusters[cluster.name] = cluster
      end
      clusters
    end

    def fetch_resource_pool(cluster_mob, resource_pool_names)
      resource_pool_mobs = @client.get_rps_by_cs_mob(cluster_mob)
      resource_pools = {}

      resource_pool_mobs.each do |resource_pool_mob|
        attr = @client.ct_mob_ref_to_attr_hash(resource_pool_mob, "RP")
        @logger.debug("resource pool in vc :#{attr["name"]} is in #{resource_pool_names}?")
        next unless resource_pool_names.include?(attr["name"])
        rp = ResourcePool.new
        rp.mob            = attr["mo_ref"]
        rp.name           = attr["name"]
        rp.shares         = attr["shares"]
        rp.host_used_mem  = attr["host_used_mem"]
        rp.guest_used_mem = attr["guest_used_mem"]
        rp.limit_mem      = attr["limit_mem"]
        rp.config_mem     = attr["config_mem"]
        rp.rev_used_mem   = attr["rev_used_mem"]
        rp.free_memory = rp.limit_mem.to_i
        if rp.limit_mem.to_i != -1
          rp.free_memory  = rp.limit_mem - rp.host_used_mem - rp.guest_used_mem
        end
        rp.unaccounted_memory = 0
        @logger.debug("Can use rp: #{rp.name} free mem:#{rp.free_memory} \n=> #{attr.pretty_inspect}")
        resource_pools[rp.name] = rp
      end

      # Get list of resource pools under this cluster
      @logger.info("Could not find requested resource pool #{resource_pool_names} under cluster #{cluster_mob}") if resource_pools.empty?
      resource_pools
    end

    def fetch_hosts(cluster, cluster_mob)
      hosts = {}
      host_mobs = @client.get_hosts_by_cs_mob(cluster_mob)
      host_mobs.each do |host_mob|
        attr = @client.ct_mob_ref_to_attr_hash(host_mob, "HS")
        host                    = Host.new
        host.cluster            = cluster
        host.datacenter         = cluster.datacenter
        host.mob                = attr["mo_ref"]
        host.name               = attr["name"]

        @logger.debug("Found host: #{host.name} @ #{host.mob}")

        host.datastores         = @client.get_datastores_by_host_mob(host_mob)
        host.total_memory       = attr["total_memory"]
        host.cpu_limit          = attr["cpu_limit"].to_i
        host.used_mem           = attr["used_mem"].to_i
        host.used_cpu           = attr["used_cpu"].to_i
        host.connection_state   = attr["connection_state"]
        @logger.debug("host.connection_state:#{host.connection_state}")
        host.mem_over_commit    = @mem_over_commit
        host.free_memory        = host.total_memory.to_i - host.used_mem.to_i
        host.unaccounted_memory = 0

        host.share_datastores = fetch_datastores(host.datastores,
                                                 host.datacenter.share_datastore_pattern)
        @logger.debug("warning: no matched sharestores in host:#{host.name}") if host.share_datastores.empty?

        host.local_datastores = fetch_datastores(host.datastores,
                                                 host.datacenter.local_datastore_pattern)
        @logger.debug("warning: no matched localstores in host:#{host.name}") if host.share_datastores.empty?

        #@logger.debug("host:#{host.name} share datastores are #{host.share_datastores}")
        #@logger.debug("host:#{host.name} local datastores are #{host.local_datastores}")

        host.vms = fetch_vms_by_host(cluster, host, host_mob)
        hosts[host.name] = host
      end
      hosts
    end

    def fetch_vms_by_host(cluster, host, host_mob)
      vms = {}
      vm_mobs = @client.get_vms_by_host_mob(host_mob)
      return vms if vm_mobs.nil?
      vm_mobs.each do |vm_mob|
        #@logger.debug("vm_mob:#{vm_mob.pretty_inspect}")
        vm_existed = @client.ct_mob_ref_to_attr_hash(vm_mob, "VM")
        vm = VHelper::CloudManager::VmInfo.new(vm_existed["name"], @logger)

        #update vm info with properties
        @client.update_vm_with_properties_string(vm, vm_existed)
        vm.host_name = host.name

        #update disk info
        #@logger.debug("vm_ex:#{vm_existed.pretty_inspect}")
        #@logger.debug("vm_:#{vm.pretty_inspect}")
        disk_attrs = @client.get_disks_by_vm_mob(vm_mob)
        disk_attrs.each do |attr|
          disk = vm.disk_add(attr['size'], attr['path'], attr['scsi_num']) 
          datastore_name = @client.get_ds_name_by_path(attr['path'])
          disk.datastore_name = datastore_name
        end

        cluster.vms[vm.name] = vm
        vms[vm.name] = vm
      end
      vms
    end

    # OK finished
    def fetch_datastores(datastore_mobs, match_patterns)
      datastores = {}
      return datastores if match_patterns.nil?
      datastore_mobs.each { |datastore_mob|
        attr = @client.ct_mob_ref_to_attr_hash(datastore_mob, "DS")
        next unless isMatched?(attr["name"], match_patterns)
        datastore                   = Datastore.new
        datastore.mob               = attr["mo_ref"]
        datastore.name              = attr["name"]

        #@logger.debug("Found datastore: #{datastore.name} @ #{datastore.mob}")

        datastore.free_space        = attr["freeSpace"]
        datastore.total_space       = attr["maxSpace"]
        datastore.unaccounted_space = 0
        datastores[datastore.name] = datastore
      }
      datastores
    end

    def isMatched?(name, match_patterns)
      #@logger.debug("isMatched? #{name}, #{match_patterns.pretty_inspect}")
      match_patterns.each { |pattern| 
        return true if name.match(pattern) 
      }
      #@logger.debug("Not Match? ")
      false
    end

    def find_cs_datastores_by_name(cluster, name)
      datastore = cluster.share_datastores[name]
      return datastore if datastore
      cluster.local_datastores[name]
    end

    def fetch_all_vms(datacenter_name, cluster_definition)
=begin
      datacenter_mob = @client.get_dc_mob_ref_by_path(datacenter_name)
      if datacenter_mob.nil?
        @logger.debug("Do not find the datacenter: #{datacenter_name}")
        raise "Do not find the datacenter: #{datacenter_name}"
      end
      cluster_mobs = @client.get_clusters_by_dc_mob(datacenter_mob)

      cluster_names = @vhelper.vc_req_clusters[0]["name"]

      clusters = {}
      @logger.debug("#{cluster_mobs.pretty_inspect}")
      cluster_mobs.each { |cluster_mob|
        @logger.debug("cluster mob:#{cluster_mob}")
        resource_pool_names = @vhelper.vc_req_clusters[0]["vc_rps"]
        resource_pools = fetch_resource_pool(cluster_mob, resource_pool_names)
        next if resource_pools.empty?

        attr = @client.ct_mob_ref_to_attr_hash(cluster_mob, "CS")
        # chose cluster in cluster_names
        next unless cluster_names.include?(attr["name"])

        vm_mobs = 
      }     
=end
    end
  end
end

