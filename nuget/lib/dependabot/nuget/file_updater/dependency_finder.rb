# frozen_string_literal: true

require "nokogiri"
require "dependabot/nuget/file_updater"
require "dependabot/nuget/update_checker"

module Dependabot
  module Nuget
    class FileUpdater
      class DependencyFinder
        def initialize(dependency:, dependency_files:, credentials:)
          @dependency          = dependency
          @dependency_files    = dependency_files
          @credentials         = credentials
        end

        def dependencies
          @dependencies ||= fetch_all_dependencies(@dependency.name, @dependency.version)
        end

        def nuget_configs
          @nuget_configs ||=
            @dependency_files.select { |f| f.name.match?(/nuget\.config$/i) }
        end

        def dependency_urls
          @dependency_urls ||=
            UpdateChecker::RepositoryFinder.new(
              dependency: @dependency,
              credentials: @credentials,
              config_files: nuget_configs
            ).dependency_urls.
            select { |url| url.fetch(:repository_type) == "v3" }
        end

        def fetch_all_dependencies(package_id, package_version, all_dependencies = Set.new)
          current_dependencies = fetch_dependencies(package_id, package_version)
          return unless current_dependencies.any?

          current_dependencies.each do |dependency|
            next if dependency.nil?
            next if all_dependencies.include?(dependency)

            dependency_id = dependency["packageName"]
            dependency_version_range = dependency["versionRange"]

            nuget_version_range_regex = /[\[(](\d+(\.\d+)*(-\w+(\.\d+)*)?)/
            nuget_version_range_match_data = nuget_version_range_regex.match(dependency_version_range)

            next if nuget_version_range_match_data.nil?

            all_dependencies.add(dependency)
            dependency_version = nuget_version_range_match_data[1]
            fetch_all_dependencies(dependency_id, dependency_version, all_dependencies)
          end
        end

        def fetch_dependencies(package_id, package_version)
          dependency_urls.
            flat_map do |url|
              fetch_dependencies_from_repository(url, package_id, package_version)
            end
        end

        def remove_wrapping_zero_width_chars(string)
          string.force_encoding("UTF-8").encode.
            gsub(/\A[\u200B-\u200D\uFEFF]/, "").
            gsub(/[\u200B-\u200D\uFEFF]\Z/, "")
        end

        def fetch_dependencies_from_repository(repository_details, package_id, package_version)
          feed_url = repository_details[:repository_url]

          # if url is azure devops
          azure_devops_regex = %r{https://pkgs\.dev\.azure\.com/(?<organization>[^/]+)/(?<project>[^/]+)/_packaging/(?<feedId>[^/]+)/nuget/v3/index\.json}
          azure_devops_match = azure_devops_regex.match(feed_url)

          if azure_devops_match
            # this is an azure devops url we will need to use a different code path to lookup dependencies
            organization = azure_devops_match[:organization]
            project = azure_devops_match[:project]
            feed_id = azure_devops_match[:feedId]

            # azure devops uses a guid to track packages across different ecosystems, we need to to an explicit call to
            # get the url for the package info
            # the URl parameters are: https://feeds.dev.azure.com/{organization}/{project}/_apis/packaging/Feeds/{feedId}/packages?protocolType=nuget&packageNameQuery={package_id}&api-version=7.0
            package_guid_url = "https://feeds.dev.azure.com/#{organization}/#{project}/_apis/packaging/Feeds/#{feed_id}/packages?protocolType=nuget&packageNameQuery=#{package_id}&api-version=7.0"
            package_guid_response = Dependabot::RegistryClient.get(
              url: package_guid_url,
              headers: repository_details[:auth_header]
            )

            return unless package_guid_response.status == 200

            package_guid_response_body = remove_wrapping_zero_width_chars(package_guid_response.body)
            package_guid_response_data = JSON.parse(package_guid_response_body)

            versions_url = nil
            package_guid_response_data["value"].each do |item|
              versions_url = item["_links"]["versions"]["href"] if item["name"] == package_id
            end

            return if versions_url.nil?

            # Now get all the dependency information for all versions of the package
            # an example url would be https://feeds.dev.azure.com/dnceng/9ee6d478-d288-47f7-aacc-f6e6d082ae6d/_apis/Packaging/Feeds/d1622942-d16f-48e5-bc83-96f4539e7601/Packages/c23152d1-3cf3-4924-8c5d-3bc5161d98ed/Versions
            # Note the 3 different guids, this makes this versions url impossible to construct without first doing the
            # "packageNameQuery" call above
            versions_response = Dependabot::RegistryClient.get(
              url: versions_url,
              headers: repository_details[:auth_header]
            )

            return unless versions_response.status == 200

            versions_response_body = remove_wrapping_zero_width_chars(versions_response.body)
            versions_response_data = JSON.parse(versions_response_body)

            matching_dependencies = []

            versions_response_data["value"].each do |entry|
              next unless entry["version"] == package_version

              entry["dependencies"].each do |dependency|
                matching_dependencies << {
                  "packageName" => dependency["packageName"],
                  "versionRange" => dependency["versionRange"]
                }
              end
            end

            matching_dependencies
          else
            # we can use the normal nuget apis to get the nuspec and list out the dependencies
            base_url = feed_url.gsub("/index.json", "-flatcontainer")
            package_id_downcased = package_id.downcase
            nuspec_url = "#{base_url}/#{package_id_downcased}/#{package_version}/#{package_id_downcased}.nuspec"

            nuspec_response = Dependabot::RegistryClient.get(
              url: nuspec_url,
              headers: repository_details[:auth_header]
            )

            return unless nuspec_response.status == 200

            nuspec_response_body = remove_wrapping_zero_width_chars(nuspec_response.body)
            nuspec_xml = Nokogiri::XML(nuspec_response_body)
            nuspec_xml.remove_namespaces!

            # we want to exclude development dependencies from the lookup
            allowed_attributes = %w(all compile native runtime)

            dependencies = nuspec_xml.xpath("//dependencies/child::node()/dependency").select do |dependency|
              include_attr = dependency.attribute("include")
              exclude_attr = dependency.attribute("exclude")

              if include_attr.nil? && exclude_attr.nil?
                true
              elsif include_attr
                include_values = include_attr.value.split(",").map(&:strip)
                include_values.intersect?(allowed_attributes)
              else
                exclude_values = exclude_attr.value.split(",").map(&:strip)
                !exclude_values.intersect?(allowed_attributes)
              end
            end

            dependency_list = []
            dependencies.each do |dependency|
              dependency_list << {
                "packageName" => dependency.attribute("id").value,
                "versionRange" => dependency.attribute("version").value
              }
            end

            dependency_list
          end
        end
      end
    end
  end
end
