# frozen_string_literal: true

module Jazari
  # Anchor resolution, shared by every path that needs a subject for an
  # AnchorTarget.
  #
  # This exists because the read path and the write path had drifted: runs
  # resolved anchors through the host's configured resolver, while customizing
  # a runbook created one directly. A host whose anchor table carries its own
  # NOT NULL columns — because it adopted jazari onto a table it already had —
  # could therefore read but never write. One resolver, used everywhere.
  module Anchors
    module_function

    # strict:  a write path; an unresolvable anchor fails closed.
    #          a read path passes false — an anchor that does not exist yet is
    #          the normal state of an uncustomized subject, not an error.
    # create:  may this call materialise the anchor? Only true when the caller
    #          is about to persist a customization.
    def resolve(target, strict: true, create: false)
      scopes = Jazari.config.anchor_scopes
      unless scopes.key?(target.scope_type)
        raise TargetNotFound, "anchor scope #{target.scope_type.inspect} is not registered"
      end

      resolver = scopes[target.scope_type]
      subject =
        if resolver.respond_to?(:call)
          # The host owns creation as well as lookup: its table may demand
          # columns the gem knows nothing about.
          resolver.call(target)
        elsif create
          Anchor.create_or_find_by!(scope_type: target.scope_type,
                                    scope_id: target.scope_id, key: target.key)
        else
          Anchor.find_by(scope_type: target.scope_type,
                         scope_id: target.scope_id, key: target.key)
        end

      return subject if subject.is_a?(ActiveRecord::Base) && subject.persisted?
      return nil unless strict

      raise TargetNotFound, "anchor #{target.key.inspect} did not resolve to a persisted record"
    end
  end
end
