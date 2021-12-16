# frozen_string_literal: true

module Autoproj
    # Access to the information contained in a package's package.xml file
    #
    # Use PackageManifest.load to create
    class RosPackageManifest < PackageManifest
        attr_accessor :name
        attr_writer :build_type

        def build_type
            @build_type || "catkin"
        end

        # @api private
        #
        # REXML stream parser object used to load the XML contents into a
        # {PackageManifest} object
        class Loader < PackageManifest::Loader
            MANIFEST_CLASS = RosPackageManifest
            SUPPORTED_MODES = %w[test doc].freeze
            DEPEND_TAGS = %w[depend build_depend build_export_depend
                             buildtool_depend buildtool_export_depend
                             exec_depend test_depend run_depend doc_depend].to_set.freeze

            def tag_start(name, attributes)
                super
                exportlevel_tag_start(name, attributes) if @export_level
            end

            def tag_end(name)
                super
                exportlevel_tag_end(name) if @export_level
            end

            def exportlevel_tag_start(name, _attributes)
                @tag_text = "" if name == "build_type"
            end

            def exportlevel_tag_end(name)
                manifest.build_type = @tag_text.strip if name == "build_type"
            end

            def toplevel_tag_start(name, attributes)
                if DEPEND_TAGS.include?(name)
                    @tag_text = ""
                elsif TEXT_FIELDS.include?(name)
                    @tag_text = ""
                elsif AUTHOR_FIELDS.include?(name)
                    @author_email = attributes["email"]
                    @tag_text = ""
                elsif name == "name"
                    @tag_text = ""
                elsif name == "export"
                    @export_level = true
                else
                    @tag_text = nil
                end
            end

            def depend_tag_end(name)
                if @tag_text.strip.empty?
                    raise InvalidPackageManifest, "found '#{name}' tag in #{path} "\
                                                  "without content"
                end

                mode = []
                if (m = /^(\w+)_depend$/.match(name))
                    mode = SUPPORTED_MODES & [m[1]]
                end

                manifest.add_dependency(@tag_text, modes: mode)
            end

            def author_tag_end(name)
                author_name = @tag_text.strip
                email = @author_email ? @author_email.strip : nil
                email = nil if email&.empty?
                contact = PackageManifest::ContactInfo.new(author_name, email)
                manifest.send("#{name}s").concat([contact])
            end

            def toplevel_tag_end(name)
                if DEPEND_TAGS.include?(name)
                    depend_tag_end(name)
                elsif AUTHOR_FIELDS.include?(name)
                    author_tag_end(name)
                elsif TEXT_FIELDS.include?(name)
                    field = @tag_text.strip
                    manifest.send("#{name}=", field) unless field.empty?
                elsif name == "name"
                    manifest.name = @tag_text.strip
                elsif name == "export"
                    @export_level = false
                end
                @tag_text = nil
            end
        end
    end
end
