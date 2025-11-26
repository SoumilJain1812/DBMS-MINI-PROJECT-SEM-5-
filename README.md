Library Management System - Complete Self-contained Package

AUTHORS: 
SOUMIL JAIN PES1UG23CS587
SOHAM U PES1UG23CS584

Files:
- app.py
- sql/library_complete.sql  (self-contained SQL that creates library_db and populates data)
- templates/ (Jinja2 templates)
- static/custom.css
- requirements.txt
- README.md (this file)

How to run:
1) Install MySQL Server. Start MySQL service.
2) Open MySQL Workbench or MySQL CLI and run the SQL file:
   File -> Run SQL Script -> select sql/library_complete.sql
   OR inside MySQL client:
     SOURCE C:/path/to/library_complete.sql;
3) Install Python packages:
   pip install -r requirements.txt
4) Edit the app.py get_db() if your MySQL root password differs.
5) Run the app:
   python app.py
6) Open http://127.0.0.1:5000

Demo logins:
- Librarians: 
      1. lib1 ; password - libpass
      2. lib2 ; password - libpass2
      3. lib3 ; password - libpass3
- Students: 
      1. akash/akashpass
      2. meera/meerpass
      3. priya2/priyapass
      4. rohit/rohitpass
      5. neha/nehapass
