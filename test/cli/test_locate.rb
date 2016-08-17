require 'autoproj/test'
require 'autoproj/cli/locate'

module Autoproj
    module CLI
        describe Locate do
            attr_reader :cli, :installation_manifest
            before do
                ws_create
                @installation_manifest = InstallationManifest.new(
                    ws.installation_manifest_path)
                @cli = Locate.new(ws, installation_manifest: installation_manifest)
            end

            describe "#validate_options" do
                it "raises if there is more than one non-option argument" do
                    assert_raises(ArgumentError) do
                        cli.validate_options(['test', 'test2'], Hash.new)
                    end
                end
                it "returns the only argument" do
                    assert_equal ['test', Hash[test: 10]],
                        cli.validate_options(['test'], Hash[test: 10])
                end
                it "returns nil as selection string if no arguments are given" do
                    assert_equal [nil, Hash[test: 10]],
                        cli.validate_options([], Hash[test: 10])
                end
            end

            describe "#find_package_set" do
                attr_reader :user_dir, :raw_dir, :pkg_set
                before do
                    @user_dir = make_tmpdir
                    @raw_dir  = make_tmpdir
                    @pkg_set = InstallationManifest::PackageSet.new(
                        'rock.core', raw_dir, user_dir)
                    installation_manifest.add_package_set(pkg_set)
                end
                it "returns nil if nothing matches" do
                    assert_nil cli.find_package_set('does.not.exist')
                end
                it "matches a package set by name" do
                    assert_same pkg_set, cli.find_package_set('rock.core')
                end
                it "matches a package set by raw local dir" do
                    assert_same pkg_set, cli.find_package_set("#{raw_dir}/")
                end
                it "matches a package set by user local dir" do
                    assert_same pkg_set, cli.find_package_set("#{user_dir}/")
                end
                it "matches a subdirectory of the raw local dir" do
                    assert_same pkg_set, cli.find_package_set("#{raw_dir}/manifests/")
                end
                it "matches a subdirectory of the user local dir" do
                    assert_same pkg_set, cli.find_package_set("#{user_dir}/test/")
                end
            end

            describe "#find_packages" do
                attr_reader :pkg
                before do
                    @pkg = InstallationManifest::Package.new(
                        'pkg', '/srcdir', '/prefix', '/builddir', [])
                    installation_manifest.add_package(pkg)
                end

                it "returns an empty array if there are no matches" do
                    assert_equal [], cli.find_packages('does/not/exist')
                end
                it "matches against the name" do
                    assert_equal [pkg], cli.find_packages('pkg')
                end
                it "matches against the source directory" do
                    assert_equal [pkg], cli.find_packages('/srcdir/')
                end
                it "matches against a subdirectory of the source directory" do
                    assert_equal [pkg], cli.find_packages('/srcdir/sub')
                end
                it "matches against the build directory" do
                    assert_equal [pkg], cli.find_packages('/builddir/')
                end
                it "matches against a subdirectory of the build directory" do
                    assert_equal [pkg], cli.find_packages('/builddir/sub')
                end
                it "handles packages without build directories" do
                    pkg.builddir = nil
                    assert_equal [pkg], cli.find_packages('/srcdir/sub')
                end
                it "returns regexp-based matches on the name if there are no exact matches" do
                    expected = %w{test0 test1}.map do |pkg_name|
                        pkg = InstallationManifest::Package.new(
                            pkg_name, '/srcdir', '/prefix', '/builddir', [])
                        installation_manifest.add_package(pkg)
                    end
                    assert_equal expected, cli.find_packages('test')
                end
                it "ignores regexp-based matches if there are exact matches" do
                    test0 = InstallationManifest::Package.new(
                        'pkg0', '/srcdir', '/prefix', '/builddir', [])
                    installation_manifest.add_package(test0)
                    test1 = InstallationManifest::Package.new(
                        'pkg1', '/srcdir', '/prefix', '/builddir', [])
                    installation_manifest.add_package(test1)
                    assert_equal [pkg], cli.find_packages('pkg')
                    assert_equal [pkg], cli.find_packages('/srcdir/')
                    assert_equal [pkg], cli.find_packages('/srcdir/sub/')
                    assert_equal [pkg], cli.find_packages('/builddir/')
                    assert_equal [pkg], cli.find_packages('/builddir/sub/')
                end
            end

            describe "#find_packages_with_directory_shortnames" do
                def add_packages(*names)
                    names.map do |n|
                        pkg = InstallationManifest::Package.new(n)
                        installation_manifest.add_package(pkg)
                        pkg
                    end
                end

                it "returns an empty array if there are no matches" do
                    add_packages 'path/to/pkg'
                    assert_equal [], cli.find_packages_with_directory_shortnames('does/not/exist')
                end
                it "matches based on partial directory prefixes" do
                    # Add other matches
                    matches = add_packages \
                        'path/to/pkg', 'possibly/to/pkg', 'path/trivially/pkg', 'path/to/potential_match'
                    # Add things that should not match
                    add_packages 'other/to/pkg', 'path/other/pkg', 'path/to/other'
                    assert_equal matches, cli.find_packages_with_directory_shortnames('p/t/p')
                end
                it "will favor a package that exactly matches the last part of the selection over the other" do
                    pkg = add_packages('path/to/pkg').first
                    add_packages 'path/to/pkg_test', 'path/to/pkg_other'
                    assert_equal [pkg], cli.find_packages_with_directory_shortnames('p/t/pkg')
                end
            end

            describe "#run" do
                it "expands a relative path to an absolute and appends a slash before matching" do
                    absolute_dir = make_tmpdir
                    dir = Pathname.new(absolute_dir).relative_path_from(Pathname.pwd).to_s
                    flexmock(cli).should_receive(:location_of).with("#{absolute_dir}/", build: false).
                        once
                    capture_subprocess_io do
                        cli.run(dir)
                    end
                end
                it "passes the build flag to #location_of" do
                    flexmock(cli).should_receive(:location_of).
                        with("a/package/name", build: true).
                        once
                    capture_subprocess_io do
                        cli.run("a/package/name", build: true)
                    end
                end
                it "displays the found path" do
                    flexmock(cli).should_receive(:location_of).
                        with("a/package/name", build: false).
                        once.and_return('/path/to/package')
                    out, _ = capture_subprocess_io do
                        cli.run('a/package/name')
                    end
                    assert_equal "/path/to/package\n", out
                end
            end

            describe "#location_of" do
                it "returns the workspace prefix if build is true and there are no selections" do
                    assert_equal ws.prefix_dir, cli.location_of(nil, build: true)
                end
                it "returns the workspace root if build is true and there are no selections" do
                    assert_equal ws.root_dir, cli.location_of(nil)
                end
                it "returns a package set's user_local_dir" do
                    flexmock(cli).should_receive(:find_package_set).
                        with(selection = flexmock).
                        and_return(flexmock(user_local_dir: 'usr/local/dir'))
                    assert_equal 'usr/local/dir', cli.location_of(selection)
                end
                it "raises NotFound if there are no matches" do
                    flexmock(cli).should_receive(:find_packages).and_return([])
                    flexmock(cli).should_receive(:find_packages_with_directory_shortnames).
                        and_return([])
                    e = assert_raises(Locate::NotFound) do
                        cli.location_of('does/not/match')
                    end
                    assert_equal "cannot find 'does/not/match' in the current autoproj installation",
                        e.message
                end
                describe "exact package resolution" do
                    it "returns a exactly resolved packages" do
                        flexmock(cli).should_receive(:find_packages).
                            with(selection = flexmock).
                            and_return([flexmock(srcdir: 'usr/local/dir')])
                        flexmock(cli).should_receive(:find_packages_with_directory_shortnames).never
                        assert_equal 'usr/local/dir', cli.location_of(selection)
                    end
                    it "returns the package's build directory if build is set" do
                        flexmock(cli).should_receive(:find_packages).
                            with(selection = flexmock).
                            and_return([flexmock(builddir: 'usr/local/dir')])
                        assert_equal 'usr/local/dir', cli.location_of(selection, build: true)
                    end
                    it "raises AmbiguousSelection if find_packages returns more than one match" do
                        flexmock(cli).should_receive(:find_packages).
                            with(selection = flexmock).
                            and_return([flexmock(name: 'pkg0', srcdir: ''), flexmock(name: 'pkg1', srcdir: '')])
                        e = assert_raises(Locate::AmbiguousSelection) do
                            cli.location_of(selection)
                        end
                        assert_equal "multiple packages match '#{selection}' in the current autoproj installation: pkg0, pkg1", e.message
                    end
                    it "disambiguates the result by filtering on the source presence" do
                        flexmock(cli).should_receive(:find_packages).
                            with(selection = flexmock).
                            and_return([
                                flexmock(name: 'pkg0', srcdir: '/pkg0'),
                                flexmock(name: 'pkg1', srcdir: '/pkg1')
                            ])
                        flexmock(File).should_receive(:directory?).and_return { |d| d == '/pkg0' }
                        assert_equal '/pkg0', cli.location_of(selection)
                    end
                end

                describe "package resolution by category prefix" do
                    before do
                        flexmock(cli).should_receive(:find_packages).and_return([])
                    end
                    it "attempts to resolve by category prefix if the exact match returns nothing" do
                        flexmock(cli).should_receive(:find_packages_with_directory_shortnames).
                            with(selection = flexmock).
                            once.and_return([flexmock(srcdir: 'usr/local/dir')])
                        assert_equal 'usr/local/dir', cli.location_of(selection)
                    end
                    it "returns the package's build directory if build is set" do
                        flexmock(cli).should_receive(:find_packages_with_directory_shortnames).
                            with(selection = flexmock).
                            once.and_return([flexmock(builddir: 'usr/local/dir')])
                        assert_equal 'usr/local/dir', cli.location_of(selection, build: true)
                    end
                    it "raises AmbiguousSelection if it returns more than one match" do
                        flexmock(cli).should_receive(:find_packages_with_directory_shortnames).
                            with(selection = flexmock).
                            and_return([flexmock(name: 'pkg0', srcdir: ''), flexmock(name: 'pkg1', srcdir: '')])
                        e = assert_raises(Locate::AmbiguousSelection) do
                            cli.location_of(selection)
                        end
                        assert_equal "multiple packages match '#{selection}' in the current autoproj installation: pkg0, pkg1", e.message
                    end
                    it "disambiguates the result by filtering on the source presence" do
                        flexmock(cli).should_receive(:find_packages_with_directory_shortnames).
                            with(selection = flexmock).
                            and_return([
                                flexmock(name: 'pkg0', srcdir: '/pkg0'),
                                flexmock(name: 'pkg1', srcdir: '/pkg1')
                            ])
                        flexmock(File).should_receive(:directory?).and_return { |d| d == '/pkg0' }
                        assert_equal '/pkg0', cli.location_of(selection)
                    end
                end
            end

            describe "#return_value" do
                it "raises ArgumentError if build: true and the package does not have a build dir" do
                    e = assert_raises(ArgumentError) do
                        cli.result_value(flexmock(name: 'pkg', builddir: nil), build: true)
                    end
                    assert_equal "pkg does not have a build directory", e.message
                end
            end
        end
    end
end

