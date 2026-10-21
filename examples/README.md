# php2shell-guard — Fleet-Beispiel (Ansible)

# Pruefung aller Hosts (read-only)
ansible-playbook -i examples/hosts.txt examples/ansible-playbook.yml --check

# Mitigation anwenden
ansible-playbook -i examples/hosts.txt examples/ansible-playbook.yml --tags mitigation

# Update
ansible-playbook -i examples/hosts.txt examples/ansible-playbook.yml --tags patch
