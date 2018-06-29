##
# Data object for storing SQL source code (parts).
#
class SourceCodeItem
  attr_accessor :code, :source_file

  def initialize
  end

  def initialize(code, source_file)
    @code = code
    @source_file = source_file
  end
end



##
# Utility class for executing PostgreSQL commands (via the psql commandline).
#
class PostgresTools

  # Static variables, be very careful with this if using threads
  @@execute_as_owner = false
  @@recorder_file = nil

  # Execute PostgreSQL command(s) outside of a database.
  def self.execute_external_sql_command(command)
    filename = $product_temp_path + 'execute_external_sql_command.tmp'
    File.open(filename, 'w') { |f| f.write(command) }
    execute_postgres_command "#{get_psql()} --dbname \"postgres\" --file \"#{filename}\" --echo-all", "Error executing SQL external command: #{command}"
    record(command)
    # External commands aren't executed from inside a database; however it seems that if you do not specify a dbname, PostgreSQL will make something up.
    # It will use the username as database name and complain if that doesn't exist. So we force "postgres" as dbname because this default database always exists.
  end

  # Execute PostgreSQL command(s) on the current database.
  def self.execute_sql_command(command, original_filename = '')
    filename = $product_temp_path + 'execute_sql_command.tmp'
    File.open(filename, 'w') { |f| f.write(command) }
    execute_postgres_command "#{get_psql()} --dbname \"#{$database_name}\" --file \"#{filename}\" --echo-all",  "Error executing SQL command: #{command}", original_filename
    record(command)
  end

  # Execute PostgreSQL command(s) on the current database, with support for {multithread} sections which will be executed in parallel.
  def self.execute_sql_command_multithread_support(command, original_filename = '')
    commands = process_sql_command_multithread(command, original_filename) # Find potential {multithread} sections and split them into separate blocks with all variables filled in.
    commands.each { |command_block|
      if command_block.is_a? Hash then
        # Command in several variations that is to be executed in parallel ({multithread} section)
        # There's a simple thread pool of $max_threads going on here.
        Thread.abort_on_exception = true
        threads = []
        $logger.publish "Running threads for: #{command_block.keys.join('; ')}..."
        work_queue = Queue.new
        command_block.each { |command_block_entry| # Put all work in the queue
          work_queue.push(command_block_entry)
        }
        $max_threads.times do # Start $max_threads threads
          threads << Thread.new {
            loop do # Each of these threads should keep on polling for work until the queue is empty
              begin
                variation_tag, command_variation = work_queue.pop(true)
              rescue ThreadError
                break # Queue empty: end of thread
              end
              variation_logger = BuildLogger.new
              variation_logger.hint_level = $hint_level
              variation_logger.open($product_log_path, '', variation_tag)
              filename = $product_temp_path + "execute_sql_command_multithread_#{variation_tag}.tmp"
              File.open(filename, 'w') { |f| f.write(command_variation) }
              psql_cmd = "#{get_psql(variation_logger)} --dbname \"#{$database_name}\" --file \"#{filename}\" --echo-all"
              execute_postgres_command psql_cmd,  "Error executing SQL command: #{command_variation}", original_filename, variation_logger
              record(command_variation)
              variation_logger.close
            end
          }
        end
        threads.each { |t| t.join } # Wait for all threads to complete
      else
        # Command that is to be executed standalone (no {multithread} section)
        $logger.publish "Running main thread..." if commands.size > 1
        execute_sql_command(command_block, original_filename)
      end
    }
  end

  # Execute a PostgreSQL command on the current database and returns the resultset as an array of hashes { columname string => value string }.
  def self.fetch_sql_command(command, original_filename = '', logger = $logger)
    filename = $product_temp_path + 'execute_sql_command.tmp'
    File.open(filename, 'w') { |f| f.write(command) }
    str = fetch_postgres_command("#{get_psql()} --dbname \"#{$database_name}\" --file \"#{filename}\" --tuples-only --expanded",  "Error executing SQL command: #{command}", original_filename, logger)
    # String to array with hashes...
    rv = []
    record = {}
    str.each_line { |line|
      line.strip!
      unless line.empty? then
        if line[0] == '-' then
          rv << record unless record.empty?
          record = {}
        else
          columnname, value = line.split('|')
          value = '' if value.nil?
          record[columnname.strip] = value.strip
        end
      end
    }
    rv << record unless record.empty? # last one too
    return rv
  end

  # Execute PostgreSQL comand(s) from a file on the current database.
  def self.execute_sql_file(filename)
    execute_postgres_command "#{get_psql()} --dbname \"#{$database_name}\" --file \"#{filename}\" --echo-all",  "Error executing SQL file: #{filename}", filename
    record(File.read(filename)) unless @@recorder_file.nil?
  end

  def self.dump_database(filename)
    execute_postgres_command "#{get_pg_dump()} --format custom --blobs --verbose --file \"#{filename}\" \"#{$database_name}\"", "Error during dump: #{filename}", filename
  end

  # Read a SQL file while processing all its references to common SQL files ({import_common ...}) recursively and processing all the dbdata folder ({data_folder}).
  # Returns the code as a string.
  def self.process_sql_file(filename, common_path, data_folder = nil)
    data_folder.chomp!('/') unless data_folder.nil? # only for search & replace
    return process_sql_file_recursive(filename, common_path, data_folder, [])
  end

  # Read a SQL file while processing all its references to common SQL files ({import_common ...}) recursively and processing all the dbdata folder ({data_folder}).
  # Return the code as a list of SourceCodeItem objects.
  def self.get_sql_code(filename, common_path, data_folder = nil)
    data_folder.chomp!('/') unless data_folder.nil? # only for search & replace
    return get_sql_code_recursive(filename, common_path, data_folder, [])
  end

  def self.start_recording(filename)
    stop_recording unless @@recorder_file.nil?
    @@recorder_file = File.open(filename, 'w')
  end

  def self.stop_recording
    @@recorder_file.close unless @@recorder_file.nil?
    @@recorder_file = nil
  end

 private

  # Commandline for psql command.
  def self.get_psql(logger = $logger)
    connectionstring = ''
    connectionstring += "--host \"#{$pg_hostname}\" " unless $pg_hostname.nil?
    connectionstring += "--port \"#{$pg_port.to_s}\" " unless $pg_port.nil?
    return "\"#{$pg_bin_path}psql\" #{connectionstring}--username \"#{$pg_username}\" --set ON_ERROR_STOP=1"
  end

  # Commandline for pg_dump command.
  def self.get_pg_dump(logger = $logger)
    connectionstring = ''
    connectionstring += "--host \"#{$pg_hostname}\" " unless $pg_hostname.nil?
    connectionstring += "--port \"#{$pg_port.to_s}\" " unless $pg_port.nil?
    return "\"#{$pg_bin_path}pg_dump\" #{connectionstring}--username \"#{$pg_username}\""
  end

  # Run a PostgreSQL commandline command; thus set PG password first.
  def self.execute_postgres_command(cmd, error_str, original_filename = '', logger = $logger)
    set_pg_password($pg_password, logger)
    logger.log 'FILE: ' + original_filename unless original_filename.empty?
    logger.log 'CMD: ' + cmd
    success = Utility.run_cmd(cmd, true, original_filename, logger)
    logger.error_sql get_sql_command_last_error_message(logger), 1000 unless success
  end

  # Run a PostgreSQL commandline command and fetch the return string
  def self.fetch_postgres_command(cmd, error_str, original_filename = '', logger = $logger)
    set_pg_password($pg_password, logger)
    logger.log 'FILE: ' + original_filename unless original_filename.empty?
    logger.log 'CMD: ' + cmd
    rv = Utility.fetch_cmd(cmd, true, original_filename, logger)
    logger.error_sql get_sql_command_last_error_message(logger), 1000 if rv.nil?
    return rv
  end

  # Parse the last error message from the command log
  def self.get_sql_command_last_error_message(logger = $logger)
    return Utility.get_last_cmd_output(IO.readlines(logger.commandlog_filename).last(15))
  end

  # Function for setting the correct PostgreSQL password (will be valid for the whole script run)
  def self.set_pg_password(pg_password, logger = $logger)
    logger.error 'PGPASSWORD environment variable is already set to a different value.' unless ENV['PGPASSWORD'].nil? || ENV['PGPASSWORD'] == pg_password
    ENV['PGPASSWORD'] = pg_password
  end

  # Processes a SQL file and returns the new content as a string.
  # Processing means filling in dbdata paths and imports from the common folders.
  def self.process_sql_file_recursive(filename, common_path, data_folder, imported_files, logger = $logger)
    if imported_files.include?(filename.strip.downcase) then
      logger.error 'Recurring or circular {import_common} detected! History:' + (imported_files + [filename.strip.downcase]).join("\n")
    end
    imported_files << filename.strip.downcase

    contents = ''
    File.open(filename, 'r') { |f| contents = f.read }

    # Replace dbdata path identifier
    contents.gsub!("{data_folder}", data_folder) unless data_folder.nil?

    # Replace import statement with file contents
    contents.gsub!(/\{import_common\s+\'(.*)\'\s*\}/i) {
      import_filename = File.expand_path(common_path + $1).fix_filename
      import_filename += '.sql' if !File.exist?(import_filename) && File.exist?(import_filename + '.sql')
      replacement = ''
      if File.exist?(import_filename) then
        if File.directory?(import_filename) then # Include an entire directory!
          import_filename = import_filename.fix_pathname
          Dir[import_filename + '**/*.sql'].sort.each { |sub_import_filename|
            sub_import_filename = sub_import_filename.fix_filename
            replacement += process_sql_file_recursive(sub_import_filename, common_path, data_folder, imported_files, logger) + "\n\n"
          }
          replacement.chomp!("\n\n")
        else
          replacement = process_sql_file_recursive(import_filename, common_path, data_folder, imported_files, logger)
        end
      else
        raise "File '#{import_filename}' not found."
      end
      replacement # Replacement value for gsub block
    }

    return contents
  end

  # Processes a SQL file and returns the new content as SourceCodeItem objects.
  # Processing means filling in dbdata paths and imports from the common folders.
  def self.get_sql_code_recursive(filename, common_path, data_folder, imported_files, logger = $logger)
    if imported_files.include?(filename.strip.downcase) then
      logger.error 'Recurring or circular {import_common} detected! History:' + (imported_files + [filename.strip.downcase]).join("\n")
    end
    imported_files << filename.strip.downcase
    

    source_code_items = []
    code_left = File.open(filename, 'r') { |f| f.read }

    matches = code_left.match(/\{import_common\s+\'(.*)\'\s*\}/i)

    while (matches) do
      from = matches.end(0)
      to = matches.begin(0) - 1

      code = code_left[0..to]
      code_left = code_left[from..-1]

      source_code_items << SourceCodeItem.new(code, filename)

      import_filename = File.expand_path(common_path + $1).fix_filename
      import_filename += '.sql' if !File.exist?(import_filename) && File.exist?(import_filename + '.sql')
      if File.exist?(import_filename) then
        if File.directory?(import_filename) then # Include an entire directory!
          import_filename = import_filename.fix_pathname
          Dir[import_filename + '**/*.sql'].sort.each { |sub_import_filename|
            sub_import_filename = sub_import_filename.fix_filename
            source_code_items.concat(get_sql_code_recursive(sub_import_filename, common_path, data_folder, imported_files, logger))
          }
        else
          source_code_items.concat(get_sql_code_recursive(import_filename, common_path, data_folder, imported_files, logger))
        end
      else
        raise "File '#{import_filename}' not found."
      end

      matches = code_left.match(/\{import_common\s+\'(.*)\'\s*\}/i) 
    end

    source_code_items << SourceCodeItem.new(code_left, filename) 

    return source_code_items
  end

  # Find {multithread ...} statements and divide the command up into subcommands with all correct variabled filled in.
  # Returns an array of strings and hashes that is to be executed sequentially. When it's a hash, all strings in the hash can be
  # executed in parallel. The hash key is the multithread-condition stringified (to be used in filenames).
  def self.process_sql_command_multithread(command, original_filename = '', logger = $logger)
    if command =~ /^\s*\{multithread[^\}]*\}\s*$/i then
      rv = []
      in_multithread_section = false
      standalone_command = ''
      multithread_hash = Hash.new('')
      resultset = []
      command.each_line { |line|
        multithread_matches = line.scan(/^\s*\{multithread\s+on\:\s*([^\}]*)\}\s*$/i).flatten # Find start tag {multithread on: ...}
        if !multithread_matches.empty? then
          rv << standalone_command.strip unless standalone_command.strip.empty? # Add potential previous standalone command
          standalone_command = ''
          logger.error 'Unexpected {multithread} section. Note: nesting is not possible, and no other statements should be on the line' if in_multithread_section
          in_multithread_section = true
          query = multithread_matches[0]
          resultset = fetch_sql_command(query, original_filename, logger)
        elsif line =~ /^\s*\{\/multithread\}\s*$/i then # End tag {/multithread}
          logger.error 'Unexpected {/multithread} section. Note: nesting is not possible, and no other statements should be on the line' unless in_multithread_section
          in_multithread_section = false
          resultset = []
          multithread_hash.delete_if { |key, value| value.strip.empty? }
          rv << multithread_hash unless multithread_hash.empty? # Add multithread commands
          multithread_hash = Hash.new('')
        else
          if in_multithread_section then
            resultset.each { |variation|
              variation_tag = (variation.map.sort.map { |_, value| value.to_s.gsub(/[^\w\d]/, '') }).to_a.join('_') # tag from values
              line_copy = line.dup
              variation.each { |columnname, value| line_copy.gsub!('{' + columnname + '}', value) } # search & replace
              multithread_hash[variation_tag] += line_copy
            }
          else
            standalone_command += line
          end
        end
      }
      logger.error 'Missing {/multithread} section. Note: nesting is not possible, and no other statements should be on the line' if in_multithread_section
      rv << standalone_command.strip unless standalone_command.strip.empty? # last one too
      return rv
    else
      return [command]
    end
  end

  def self.record(sql, *options)
    unless @@recorder_file.nil?
      appender = "\n\n"
      appender = ';' + appender unless sql.strip.end_with?(';')
      @@recorder_file.write(sql + appender)  # I think write operations are atomic, i.e. thread-safe.
    end
  end

end