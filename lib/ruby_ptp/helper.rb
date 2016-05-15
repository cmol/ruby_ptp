module RubyPtp
  class Helper
    def self.write_data(path: "./", files: nil)
      files.each do |file|
        File.open(path+file[:name]+".dat", 'w') do |f|
          puts "Writing file #{file[:name]}"
          idx = -1
          f.write("x\ty\n")
          file[:data].each do |d|
            idx += 1
            next unless d
            if file[:name] =~ /freq.*/
              d = (d - 1) * 1000000
            end
            f.write("#{idx}\t#{d.to_f}\n")
          end
        end
      end
    end
  end
end
