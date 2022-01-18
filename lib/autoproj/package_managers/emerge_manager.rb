module Autoproj
    module PackageManagers
        # Package manager interface for systems that use emerge (i.e. gentoo) as
        # their package manager
        class EmergeManager < ShellScriptManager
            class << self
                def inherit
                    @inherit ||= Set.new
                end
            end

            def initialize(ws)
                @installed_cache = {}
                @uptodate_cache = {}
                super(ws, true,
                        %w[emerge],
                        %w[emerge --noreplace])
            end

            def configure_manager
                super
                ws.config.declare(
                    "emerge_update", "boolean",
                    default: "yes",
                    doc: ["Would you like autoproj to keep emerge packages up-to-date?"]
                )
                keep_uptodate?
            end

            def keep_uptodate?
                ws.config.get("emerge_update")
            end

            def keep_uptodate=(flag)
                ws.config.set("emerge_update", flag, true)
            end

            def update_package_information_from_emerge(package_names)

                if package_names.kind_of?(String)
                    package_names = [package_names]
                end

                # emerge -p1 --nodeps --quiet --color n <package_name>
                # exitcode != 0 when package_name is ambigous or unknown
                # when the package would be rebuilt(i.E. it does not need to be updated)
                #  outputs: [ebuild   R   ] full_package_name_with_version
                # when the package will be added new
                #  outputs: [ebuild  N    ] full_package_name_with_version
                # when a newer version is available/requested
                #  outputs: [ebuild     U ] full_package_name_with_version
                #  outputs: [ebuild     UD] full_package_name_with_version

                emerge_output = `emerge -p1 --nodeps --quiet --color n #{package_names.map{|s| "'#{s}'"}.join(" ")}`
                if !$?.success?
                    puts "There is a problem resolving os packages #{package_names.map{|s| "'#{s}'"}.join(" ")}"
                end

                package_names.each do |package_name|
                    @installed_cache[package_name] = false
                    @uptodate_cache[package_name] = false
                end

                emerge_output.each_line do |line|
                    if /^\[ebuild([^\]]*)\]\s+(.*)$/ =~ line
                        update_flags = $~[1]
                        fpv = $~[2]
                        fp = fpv
                        fp = fp.gsub(/-r[^-]+$/,"")
                        fp = fp.gsub(/-[^-]+$/,"")
                        package_name = nil
                        package_names.each do |atom|
                            name = atom
                            if /^[<>=]+(.*)$/ =~ name
                                name = $~[1]
                                name = name.gsub(/-r[^-]+$/,"")
                                name = name.gsub(/-[^-]+$/,"")
                            end
                            name = name.gsub(/\[.*\]$/,"")
                            name = name.gsub(/:.*$/,"")
                            #name is atom minus comparison op, version and useflags
                            if name == fp
                                package_name = atom
                                break
                            end
                        end
                        if /R/ =~ update_flags
                            @installed_cache[package_name] = true
                            @uptodate_cache[package_name] = true
                        elsif /N/ =~ update_flags
                            @installed_cache[package_name] = false
                            @uptodate_cache[package_name] = false
                        else
                            @installed_cache[package_name] = true
                            @uptodate_cache[package_name] = false
                        end

                        package_names.delete(package_name)
                    end
                end

                #for the rest, try calling it one name at a time
                #for package_names to be non-empty, we would have to be
                #unable to match some of the entries.
                package_names.each do |package_name|

                    emerge_output = `emerge -p1 --nodeps --quiet --color n '#{package_name}'`
                    if !$?.success?
                        puts "There is a problem resolving os packages '#{package_name}'"
                        @installed_cache[package_name] = false
                        @uptodate_cache[package_name] = false
                    end
                    if /\[ebuild[^\]]*[R][^\]]*\]/ =~ emerge_output
                        @installed_cache[package_name] = true
                        @uptodate_cache[package_name] = true
                    elsif /\[ebuild[^\]]*[N][^\]]*\]/ =~ emerge_output
                        @installed_cache[package_name] = false
                        @uptodate_cache[package_name] = false
                    elsif /\[ebuild[^\]]*\]/ =~ emerge_output
                        @installed_cache[package_name] = true
                        @uptodate_cache[package_name] = false
                    else
                        puts "There is a problem resolving os packages '#{package_name}'"
                        @installed_cache[package_name] = false
                        @uptodate_cache[package_name] = false
                    end
                end
            end

            def update_package_information(package_name)
                # we can only ask emerge about it. we cache results.
                # rationale: the package_name specification is a bit on the
                # complicated side:
                # ['='|'<'|'>='|'<'|'<='][<category>'/']<name>['-'<version>['-r'<revision>]][':'<slot>[/<slotversion>]]['['<useflagspec>']']
                # where useflagspec is a comma separated list of flags to be active ("flag") and flags to be inactive ("-flag")
                # package information is in /var/db/pkg/<category>'/'<name>'-'<version>['-r'<revision>]
                # inside, files SLOT and USE provide the remaining bits.

                pkg_db = '/var/db/pkg'

                if /^[-a-zA-Z0-9_+]+$/ =~ package_name
                    # must scan all categories, punt if we find multiple
                    # categories
                    candidates = []
                    categories = {}
                    Dir.each_child(pkg_db) do |category|
                        Dir.glob("#{package_name}*", :base => "#{pkg_db}/#{category}") do |package|
                            candidates << "#{category}/%{package}"
                            categories[category] = 1
                        end
                    end
                    if categories.length == 0
                        @installed_cache[package_name] = false
                    elsif categories.length == 1
                        @installed_cache[package_name] = true
                    else
                        puts "Ambigous package name #{package_name}, candidates: "+candidates.join(", ")
                    end
                    return
                elsif /^[-a-z0-9]+\/[-a-zA-Z0-9_+]+$/ =~ package_name
                    # note that there is no comparison operator in front,
                    # so all of this is part of the name, no version attached.
                    candidates = []
                    @installed_cache[package_name] = false
                    if Dir.glob("#{package_name}*", :base => pkg_db)
                        @installed_cache[package_name] = true
                    end
                    return
                elsif /^([-a-z0-9]+\/[-a-zA-Z0-9_+]+):([-a-zA-Z0-9_+\/]+)$/ =~ package_name
                    # as above, but has a slot, so need to check SLOT in the
                    # package directories.
                    package = $~[1]
                    slot = $~[2]
                    @installed_cache[package_name] = false
                    Dir.glob("#{package}*", :base => pkg_db) do |dirname|
                        thisslot = File.open("#{pkg_db}/#{dirname}/SLOT") { |f| f.gets; }
                        if slot == thisslot || /^#{slot}\s/ =~ thisslot ||
                            /^#{slot}\// =~ thisslot
                            @installed_cache[package_name] = true
                        end
                    end
                    return
                end

                # fallback to asking emerge
                update_package_information_from_emerge(package_name)
            end

            # checks if the provided package is installed
            # and returns true if it is the case
            def installed?(package_name, filter_uptodate_packages: false,
                install_only: false)

                if !@installed_cache.include?(package_name)
                    update_package_information(package_name)
                end

                return @installed_cache[package_name]
            end

            def updated?(package_name)
                if !@uptodate_cache.include?(package_name)
                    update_package_information_from_emerge(package_name)
                end
                @uptodate_cache[package_name]
            end

            def install(packages, filter_uptodate_packages: false, install_only: false)
                if filter_uptodate_packages || install_only
                    already_installed, missing = packages.partition do |package_name|
                        installed?(package_name)
                    end

                    if keep_uptodate? && !install_only
                        update_package_information_from_emerge(already_installed)
                        need_update = already_installed.find_all do |package_name|
                            !updated?(package_name)
                        end
                    end
                    packages = missing + (need_update || [])
                end

                if super(packages, inherit: self.class.inherit)
                    # Invalidate caching of installed packages, as we just
                    # installed new packages !
                    @installed_cache = {}
                    @uptodate_cache = {}
                end
            end
        end
    end
end
