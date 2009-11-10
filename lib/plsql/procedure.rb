module PLSQL

  module ProcedureClassMethods
    def find(schema, procedure, package = nil, override_schema_name = nil)
      if package.nil?
        if schema.select_first("
            SELECT object_name FROM all_objects
            WHERE owner = :owner
              AND object_name = :object_name
              AND object_type IN ('PROCEDURE','FUNCTION')",
            schema.schema_name, procedure.to_s.upcase)
          new(schema, procedure)
        # search for synonym
        elsif (row = schema.select_first("
            SELECT o.owner, o.object_name
            FROM all_synonyms s, all_objects o
            WHERE s.owner IN (:owner, 'PUBLIC')
              AND s.synonym_name = :synonym_name
              AND o.owner = s.table_owner
              AND o.object_name = s.table_name
              AND o.object_type IN ('PROCEDURE','FUNCTION')
              ORDER BY DECODE(s.owner, 'PUBLIC', 1, 0)",
            schema.schema_name, procedure.to_s.upcase))
          new(schema, row[1], nil, row[0])
        else
          nil
        end
      elsif package && schema.select_first("
            SELECT object_name FROM all_procedures
            WHERE owner = :owner
              AND object_name = :object_name
              AND procedure_name = :procedure_name
          ", override_schema_name || schema.schema_name, package, procedure.to_s.upcase)
        new(schema, procedure, package, override_schema_name)
      else
        nil
      end
    end
  end

  class Procedure
    extend ProcedureClassMethods

    attr_reader :arguments, :argument_list, :out_list, :return
    attr_reader :schema, :schema_name, :package, :procedure

    def initialize(schema, procedure, package = nil, override_schema_name = nil)
      @schema = schema
      @schema_name = override_schema_name || schema.schema_name
      @procedure = procedure.to_s.upcase
      @package = package
      @arguments = {}
      @argument_list = {}
      @out_list = {}
      @return = {}
      @overloaded = false

      # store reference to previous level record or collection metadata
      previous_level_argument_metadata = {}

      # RSI: due to 10gR2 all_arguments performance issue SELECT split into two statements
      # added condition to ensure that if object is package then package specification not body is selected
      object_id = @schema.connection.select_first("
        SELECT o.object_id
        FROM all_objects o
        WHERE o.owner = :owner
        AND o.object_name = :object_name
        AND o.object_type <> 'PACKAGE BODY'
        ", @schema_name, @package ? @package : @procedure
      )[0] rescue nil
      num_rows = @schema.connection.select_all("
        SELECT overload, argument_name, position, data_level,
              data_type, in_out, data_length, data_precision, data_scale, char_used,
              type_owner, type_name, type_subname
        FROM all_arguments
        WHERE object_id = :object_id
        AND owner = :owner
        AND object_name = :procedure_name
        AND NVL(package_name,'nil') = :package
        ORDER BY overload, sequence
        ", object_id, @schema_name, @procedure, @package ? @package : 'nil'
      ) do |r|

        overload, argument_name, position, data_level,
            data_type, in_out, data_length, data_precision, data_scale, char_used,
            type_owner, type_name, type_subname = r

        @overloaded ||= !overload.nil?
        # if not overloaded then store arguments at key 0
        overload ||= 0
        @arguments[overload] ||= {}
        @return[overload] ||= nil

        raise ArgumentError, "Parameter type definition inside package is not supported, use CREATE TYPE outside package" if type_subname

        argument_metadata = {
          :position => position && position.to_i,
          :data_type => data_type,
          :in_out => in_out,
          :data_length => data_length && data_length.to_i,
          :data_precision => data_precision && data_precision.to_i,
          :data_scale => data_scale && data_scale.to_i,
          :char_used => char_used,
          :type_owner => type_owner,
          :type_name => type_name,
          :type_subname => type_subname,
          :sql_type_name => "#{type_owner}.#{type_name}"
        }
        if composite_type?(data_type)
          case data_type
          when 'PL/SQL RECORD'
            argument_metadata[:fields] = {}
          end
          previous_level_argument_metadata[data_level] = argument_metadata
        end

        # if parameter
        if argument_name
          # top level parameter
          if data_level == 0
            @arguments[overload][argument_name.downcase.to_sym] = argument_metadata
          # or lower level part of composite type
          else
            case previous_level_argument_metadata[data_level - 1][:data_type]
            when 'PL/SQL RECORD'
              previous_level_argument_metadata[data_level - 1][:fields][argument_name.downcase.to_sym] = argument_metadata
            when 'TABLE', 'VARRAY'
              previous_level_argument_metadata[data_level - 1][:element] = argument_metadata
            end
          end
        # if function has return value
        elsif argument_name.nil? && data_level == 0 && in_out == 'OUT'
          @return[overload] = argument_metadata
        end
      end
      # if procedure is without arguments then create default empty argument list for default overload
      @arguments[0] = {} if @arguments.keys.empty?
      
      @overloads = @arguments.keys.sort
      @overloads.each do |overload|
        @argument_list[overload] = @arguments[overload].keys.sort {|k1, k2| @arguments[overload][k1][:position] <=> @arguments[overload][k2][:position]}
        @out_list[overload] = @argument_list[overload].select {|k| @arguments[overload][k][:in_out] =~ /OUT/}
      end
    end

    PLSQL_COMPOSITE_TYPES = ['PL/SQL RECORD', 'TABLE', 'VARRAY'].freeze
    def composite_type?(data_type)
      PLSQL_COMPOSITE_TYPES.include? data_type
    end

    def overloaded?
      @overloaded
    end

    def exec(*args)
      call = ProcedureCall.new(self, args)
      call.exec
    end

  end

end