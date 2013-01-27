require 'yaml'
require 'csv'
require 'yajl'
require 'open-uri'
require 'ruby-progressbar'

class SkyDB
  class Import
    class Importer
      ##########################################################################
      #
      # Errors
      #
      ##########################################################################

      class UnsupportedFileType < StandardError; end
      class TransformNotFound < StandardError; end
      

      ##########################################################################
      #
      # Constructor
      #
      ##########################################################################

      # Initializes the importer.
      def initialize(options={})
        @translators = []

        self.client = options[:client] || SkyDB.client
        self.table_name  = options[:table_name]
        self.format = options[:format]
        self.files  = options[:files] || []
      end
    

      ##########################################################################
      #
      # Attributes
      #
      ##########################################################################

      # The client to access the Sky server with.
      attr_accessor :client

      # The name of the table to import into.
      attr_accessor :table_name

      # The format file to use for translating the input data.
      attr_accessor :format

      # A list of translators to use to convert input rows into output rows.
      attr_reader :translators

      # A list of files to input from.
      attr_accessor :files

      # A list of header names to use for CSV files. Using this option will
      # treat the CSV input as not having a header row.
      attr_accessor :headers


      ##########################################################################
      #
      # Methods
      #
      ##########################################################################
    
      ##################################
      # Import
      ##################################
    
      # Imports records from a list of files.
      #
      # @param [Array]  a list of files to import.
      def import(files, options={})
        options[:progress_bar] = true unless options.has_key?(:progress_bar)
        progress_bar = nil
        
        # Set the table to import into.
        SkyDB.table_name = table_name
        
        # Loop over each of the files.
        files = [files] unless files.is_a?(Array)
        files.each do |file|
          # Initialize progress bar.
          count = %x{wc -l #{file}}.split.first.to_i
          progress_bar = ::ProgressBar.create(
            :total => count,
            :format => ('%-40s' % file) + ' |%B| %P%%'
          ) if options[:progress_bar]

          SkyDB.multi(:max_count => 1000) do
            each_record(file) do |input|
              # Convert input line to a symbolized hash.
              output = translate(input)
              output._symbolize_keys!
              
              # p output

              if !(output[:object_id] > 0)
                progress_bar.clear() unless progress_bar.nil?
                $stderr.puts "[ERROR] Invalid object id on line #{$.}"
              elsif output[:timestamp].nil?
                progress_bar.clear() unless progress_bar.nil?
                $stderr.puts "[ERROR] Invalid timestamp on line #{$.}"
              else
                # Convert hash to an event and send to Sky.
                event = SkyDB::Event.new(output)
                SkyDB.add_event(event)
              end
            
              # Update progress bar.
              progress_bar.increment() unless progress_bar.nil?
            end
          end

          # Finish progress bar.
          progress_bar.finish() unless progress_bar.nil? || progress_bar.finished?
        end
        
        return nil
      end


      ##################################
      # Iteration
      ##################################
    
      # Executes a block for each record in a given file. A record is defined
      # by the file's type (:csv, :tsv, :json).
      #
      # @param [String] file  the path to the file to iterate over.
      # @param [String] file_type  the type of file to process.
      def each_record(file, file_type=nil)
        # Determine file type automatically if not passed in.
        file_type ||= 
          case File.extname(file)
          when '.tsv' then :tsv
          when '.txt' then :tsv
          when '.json' then :json
          when '.csv' then :csv
          end
        
        # Process the record by file type.
        case file_type
        when :csv then each_text_record(file, ",", &Proc.new)
        when :tsv then each_text_record(file, "\t", &Proc.new)
        when :json then each_json_record(file, &Proc.new)
        else raise SkyDB::Import::Importer::UnsupportedFileType.new("File type not supported by importer: #{file_type || File.extname(file)}")
        end
        
        return nil
      end
      
      # Executes a block for each line of a delimited flat file format
      # (CSV, TSV).
      #
      # @param [String] file  the path to the file to iterate over.
      # @param [String] col_sep  the column separator.
      def each_text_record(file, col_sep)
        # Process each line of the CSV file.
        CSV.foreach(file, :headers => headers.nil?, :col_sep => col_sep) do |row|
          record = nil
          
          # If headers were not specified then use the ones from the
          # CSV file and just convert the row to a hash.
          if headers.nil?
            record = row.to_hash
          
          # If headers were specified then manually convert the row
          # using the headers provided.
          else
            record = {}
            headers.each_with_index do |header, index|
              record[header] = row[index]
            end
          end

          yield(record)
        end
      end

      # Executes a block for each line of a JSON file.
      #
      # @param [String] file  the path to the file to iterate over.
      def each_json_record(file)
        io = open(file)

        # Process each line of the JSON file.
        Yajl::Parser.parse(io) do |record|
          yield(record)
        end
      end


      ##################################
      # Translation
      ##################################

      # Translates an input hash into an output hash using the translators.
      #
      # @param [Hash]  the input hash.
      #
      # @return [Hash]  the output hash.
      def translate(input)
        output = {}

        translators.each do |translator|
          translator.translate(input, output)
        end

        return output
      end
      
      
      ##################################
      # Transform Management
      ##################################
    
      # Parses and appends the contents of a transform file to the importer.
      #
      # @param [String]  the YAML formatted transform file.
      def load_transform(content)
        # Parse the transform file.
        transform = {'fields' => {}}.merge(YAML.load(content))

        # Load any libraries requested by the format file.
        if transform['require'].is_a?(Array)
          transform['require'].each do |library_name|
            require library_name
          end
        end

        # Load individual field translations.
        load_transform_fields(transform['fields'])
        
        # Load a free-form translate function if specified.
        if !transform['translate'].nil?
          @translators << Translator.new(
            :translate_function => transform['translate']
          )
        end
        
        return nil
      end

      # Loads a hash of transforms.
      #
      # @param [Hash]  the hash of transform info.
      # @param [Array]  the path of fields.
      def load_transform_fields(fields, path=nil)
        # Convert each field to a translator.
        fields.each_pair do |key, value|
          translator = Translator.new(:output_field => (path.nil? ? key : path.clone.concat([key])))

          # Load a regular transform.
          if value.is_a?(String)
            # If the line is wrapped in curly braces then generate a translate function.
            m, code = *value.match(/^\s*\{(.*)\}\s*$/)
            if !m.nil?
              translator.translate_function = code
          
            # Otherwise it's a colon-separated field describing the input field and data type.
            else
              input_field, format = *value.strip.split(":")
              translator.input_field = input_field
              translator.format = format
            end

          # If this field is a hash then load it as a nested transform.
          elsif value.is_a?(Hash)
            load_transform_fields(value, path.to_a.clone.flatten.concat([key]))
          
          else
            raise "Invalid data type for '#{key}' in transform file: #{value.class}"
          end
          
          # Append to the list of translators.
          @translators << translator
        end
      end


      # Parses and appends the contents of a transform file to the importer.
      #
      # @param [String]  the filename to load from.
      def load_transform_file(filename)
        transforms_path = File.expand_path(File.join(File.dirname(__FILE__), 'transforms'))
        named_transform_path = File.join(transforms_path, "#{filename}.yml")
        
        # If it's just a word then find it in the gem.
        if filename.index(/^\w+$/)
          raise TransformNotFound.new("Named transform not available: #{filename} (#{named_transform_path})") unless File.exists?(named_transform_path)
          return load_transform(IO.read(named_transform_path))

        # Otherwise load it from the present working directory.
        else
          raise TransformNotFound.new("Transform file not found: #{filename}") unless File.exists?(filename)
          return load_transform(IO.read(filename))
        end
      end
    end
  end
end