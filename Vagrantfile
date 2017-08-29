# -*- mode: ruby -*-
# vi: set ft=ruby :

# Vagrantfile API/syntax version. Don't touch unless you know what you're doing!
VAGRANTFILE_API_VERSION = "2"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.box = "arch"
  config.vm.provider :virtualbox do |vb|
    vb.gui = true
    vb.cpus = 2
    vb.memory = 1024
  end
  config.vm.provision "ansible", run: "always" do |ansible|
    ansible.playbook = "playbook.yml"
    ansible.extra_vars = {
      is_vagrant: "True",
      user_password: "vagrant-password",
    }
  end
end
