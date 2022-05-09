# frozen_string_literal: true

# typed: strict

require 'set'
require 'teams'
require 'sorbet-runtime'
require 'json'
require 'parse_packwerk'
require 'code_ownership/cli'
require 'code_ownership/private'

module CodeOwnership
  extend self
  extend T::Sig
  extend T::Helpers

  requires_ancestor { Kernel }

  sig { params(file: String).returns(T.nilable(Teams::Team)) }
  def for_file(file)
    @for_file ||= T.let(@for_file, T.nilable(T::Hash[String, T.nilable(Teams::Team)]))
    @for_file ||= {}

    return nil if file.start_with?('./')
    return @for_file[file] if @for_file.key?(file)

    owner = T.let(nil, T.nilable(Teams::Team))

    Private.mappers.each do |mapper|
      owner = mapper.map_file_to_owner(file)
      break if owner
    end

    @for_file[file] = owner
  end

  class InvalidCodeOwnershipConfigurationError < StandardError
  end

  sig { params(filename: String).void }
  def self.remove_file_annotation!(filename)
    Private.file_annotations_mapper.remove_file_annotation!(filename)
  end

  sig do
    params(
      files: T::Array[String],
      autocorrect: T::Boolean,
      stage_changes: T::Boolean
    ).void
  end
  def validate!(
    files: Private.tracked_files,
    autocorrect: true,
    stage_changes: true
  )
    tracked_file_subset = Private.tracked_files & files
    Private.validate!(files: tracked_file_subset, autocorrect: autocorrect, stage_changes: stage_changes)
  end

  # Given a backtrace from either `Exception#backtrace` or `caller`, find the
  # first line that corresponds to a file with assigned ownership
  sig { params(backtrace: T.nilable(T::Array[String]), excluded_teams: T::Array[::Teams::Team]).returns(T.nilable(::Teams::Team)) }
  def for_backtrace(backtrace, excluded_teams: [])
    return unless backtrace

    # The pattern for a backtrace hasn't changed in forever and is considered
    # stable: https://github.com/ruby/ruby/blob/trunk/vm_backtrace.c#L303-L317
    #
    # This pattern matches a line like the following:
    #
    #   ./app/controllers/some_controller.rb:43:in `block (3 levels) in create'
    #
    backtrace_line = %r{\A(#{Pathname.pwd}/|\./)?
        (?<file>.+)       # Matches 'app/controllers/some_controller.rb'
        :
        (?<line>\d+)      # Matches '43'
        :in\s
        `(?<function>.*)' # Matches "`block (3 levels) in create'"
      \z}x

    backtrace.each do |line|
      match = line.match(backtrace_line)

      if match
        team = CodeOwnership.for_file(T.must(match[:file]))
        if team && !excluded_teams.include?(team)
          return team
        end
      end
    end
    nil
  end

  sig { params(klass: T.nilable(T.any(Class, Module))).returns(T.nilable(::Teams::Team)) }
  def for_class(klass)
    @memoized_values ||= T.let(@memoized_values, T.nilable(T::Hash[String, T.nilable(::Teams::Team)]))
    @memoized_values ||= {}
    # We use key because the memoized value could be `nil`
    if !@memoized_values.key?(klass.to_s)
      path = Private.path_from_klass(klass)
      return nil if path.nil?

      value_to_memoize = for_file(path)
      @memoized_values[klass.to_s] = value_to_memoize
      value_to_memoize
    else
      @memoized_values[klass.to_s]
    end
  end

  sig { params(package: ParsePackwerk::Package).returns(T.nilable(::Teams::Team)) }
  def for_package(package)
    Private::OwnershipMappers::PackageOwnership.new.owner_for_package(package)
  end

  # Generally, you should not ever need to do this, because once your ruby process loads, cached content should not change.
  # Namely, the set of files, packages, and directories which are tracked for ownership should not change.
  # The primary reason this is helpful is for clients of CodeOwnership who want to test their code, and each test context
  # has different ownership and tracked files.
  sig { void }
  def self.bust_caches!
    @for_file = nil
    @memoized_values = nil
    Private.bust_caches!
    Private.mappers.each(&:bust_caches!)
  end
end
