module RubyPtp
  class Helper
    def self.write_data(path: "./", files: nil)
      files.each do |file|
        File.open(path+file[:name]+".dat", 'w') do |f|
          idx = 0
          f.write("x\ty\n")
          file[:data].each do |d|
            f.write("#{idx}\t#{d.to_f}\n")
            idx += 1
          end
        end
      end
    end
  end
end
