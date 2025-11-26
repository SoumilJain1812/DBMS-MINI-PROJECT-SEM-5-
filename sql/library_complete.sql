-- library_complete_fixed.sql
-- Corrected & self-contained SQL for library_db
-- (fixed column name, ENUM values, and procedure variable declarations)

DROP DATABASE IF EXISTS library_db;
CREATE DATABASE library_db;
USE library_db;

-- Core tables
CREATE TABLE books (
  BookID INT AUTO_INCREMENT PRIMARY KEY,
  ISBN VARCHAR(50) UNIQUE,
  Title VARCHAR(255) NOT NULL,
  Author VARCHAR(255),
  Publisher VARCHAR(255),
  Year INT,
  Category VARCHAR(100),
  TotalCopies INT DEFAULT 1,
  AvailableCopies INT DEFAULT 1,
  Description TEXT,
  ISBN13 VARCHAR(50),
  CreatedAt TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE students (
  StudentID INT AUTO_INCREMENT PRIMARY KEY,
  RollNo VARCHAR(30) UNIQUE,
  Name VARCHAR(255) NOT NULL,
  Department VARCHAR(100),
  Email VARCHAR(255),
  Phone VARCHAR(20),
  CreatedAt TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE staff (
  StaffID INT AUTO_INCREMENT PRIMARY KEY,
  Name VARCHAR(255) NOT NULL,
  Role VARCHAR(100),
  Email VARCHAR(255),
  Phone VARCHAR(20),
  CreatedAt TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE users (
  UserID INT AUTO_INCREMENT PRIMARY KEY,
  Username VARCHAR(100) UNIQUE,
  Password VARCHAR(255),
  Role ENUM('librarian','student') DEFAULT 'student',
  LinkedID INT,
  CreatedAt TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE borrow_records (
  RecordID INT AUTO_INCREMENT PRIMARY KEY,
  StudentID INT,
  BookID INT,
  IssueDate DATE,
  DueDate DATE,
  ReturnDate DATE,
  Fine DECIMAL(8,2) DEFAULT 0,
  Returned BOOLEAN DEFAULT FALSE,
  IssuedBy INT,
  ReturnedBy INT,
  CreatedAt TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (StudentID) REFERENCES students(StudentID),
  FOREIGN KEY (BookID) REFERENCES books(BookID),
  FOREIGN KEY (IssuedBy) REFERENCES staff(StaffID),
  FOREIGN KEY (ReturnedBy) REFERENCES staff(StaffID)
);

-- NOTE: Column renamed to BookCondition (Condition is a problematic identifier)
CREATE TABLE book_copies (
  CopyID INT AUTO_INCREMENT PRIMARY KEY,
  BookID INT NOT NULL,
  Barcode VARCHAR(100) UNIQUE,
  BookCondition VARCHAR(100) DEFAULT 'Good',
  Status ENUM('available','issued','reserved','lost','maintenance') DEFAULT 'available',
  AddedAt TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (BookID) REFERENCES books(BookID)
);

CREATE TABLE reservations (
  ReservationID INT AUTO_INCREMENT PRIMARY KEY,
  StudentID INT,
  BookID INT,
  CopyID INT,
  ReservationDate DATETIME DEFAULT CURRENT_TIMESTAMP,
  ExpiresAt DATETIME,
  Status ENUM('active','cancelled','fulfilled','expired') DEFAULT 'active',
  FOREIGN KEY (StudentID) REFERENCES students(StudentID),
  FOREIGN KEY (BookID) REFERENCES books(BookID),
  FOREIGN KEY (CopyID) REFERENCES book_copies(CopyID)
);

CREATE TABLE payments (
  PaymentID INT AUTO_INCREMENT PRIMARY KEY,
  RecordID INT,
  StudentID INT,
  Amount DECIMAL(8,2),
  PaidAt DATETIME DEFAULT CURRENT_TIMESTAMP,
  Method VARCHAR(100),
  FOREIGN KEY (RecordID) REFERENCES borrow_records(RecordID),
  FOREIGN KEY (StudentID) REFERENCES students(StudentID)
);

CREATE TABLE audit_logs (
  LogID INT AUTO_INCREMENT PRIMARY KEY,
  ActorUserID INT,
  ActionType VARCHAR(100),
  ActionDetails TEXT,
  ActionTime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE extensions (
  ExtensionID INT AUTO_INCREMENT PRIMARY KEY,
  RecordID INT,
  RequestedOn DATETIME DEFAULT CURRENT_TIMESTAMP,
  NewDueDate DATE,
  Status ENUM('pending','approved','rejected') DEFAULT 'pending',
  ProcessedBy INT NULL,
  ProcessedOn DATETIME NULL,
  FOREIGN KEY (RecordID) REFERENCES borrow_records(RecordID),
  FOREIGN KEY (ProcessedBy) REFERENCES staff(StaffID)
);

CREATE TABLE reviews (
  ReviewID INT AUTO_INCREMENT PRIMARY KEY,
  BookID INT,
  StudentID INT,
  Rating TINYINT,
  Comment TEXT,
  CreatedAt TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (BookID) REFERENCES books(BookID),
  FOREIGN KEY (StudentID) REFERENCES students(StudentID)
);

-- function to calculate fine
DELIMITER $$
DROP FUNCTION IF EXISTS calc_fine$$
CREATE FUNCTION calc_fine(due DATE, returned DATE) RETURNS DECIMAL(8,2)
DETERMINISTIC
BEGIN
  DECLARE days_overdue INT;
  DECLARE rate DECIMAL(6,2) DEFAULT 5.00;
  IF returned IS NULL THEN
    SET days_overdue = DATEDIFF(CURDATE(), due);
  ELSE
    SET days_overdue = DATEDIFF(returned, due);
  END IF;
  IF days_overdue > 0 THEN RETURN days_overdue * rate; ELSE RETURN 0; END IF;
END$$
DELIMITER ;

-- procedures: issue, return, create copies, reserve, request extension
DELIMITER $$
DROP PROCEDURE IF EXISTS issue_book$$
CREATE PROCEDURE issue_book(IN p_student INT, IN p_book INT, IN p_issued_by INT)
BEGIN
  DECLARE avail INT;
  SELECT AvailableCopies INTO avail FROM books WHERE BookID = p_book FOR UPDATE;
  IF avail IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Book not found';
  ELSEIF avail <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No copies available';
  ELSE
    UPDATE books SET AvailableCopies = AvailableCopies - 1 WHERE BookID = p_book;
    INSERT INTO borrow_records (StudentID, BookID, IssueDate, DueDate, IssuedBy, Returned)
    VALUES (p_student, p_book, CURDATE(), DATE_ADD(CURDATE(), INTERVAL 14 DAY), p_issued_by, FALSE);
  END IF;
END$$

DROP PROCEDURE IF EXISTS return_book$$
CREATE PROCEDURE return_book(IN p_record INT, IN p_returned_by INT)
BEGIN
  DECLARE b_id INT;
  DECLARE due DATE;
  DECLARE ret DATE;
  DECLARE already_returned BOOLEAN;

  -- select into declared variables
  SELECT BookID, DueDate, ReturnDate, Returned
    INTO b_id, due, ret, already_returned
  FROM borrow_records
  WHERE RecordID = p_record
  FOR UPDATE;

  IF b_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Borrow record not found';
  ELSEIF already_returned = TRUE THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Book already returned';
  ELSE
    SET @rdate = CURDATE();
    UPDATE borrow_records
      SET ReturnDate = @rdate,
          Fine = calc_fine(due, @rdate),
          Returned = TRUE,
          ReturnedBy = p_returned_by
    WHERE RecordID = p_record;
    UPDATE books SET AvailableCopies = AvailableCopies + 1 WHERE BookID = b_id;
  END IF;
END$$

DROP PROCEDURE IF EXISTS create_book_copies$$
CREATE PROCEDURE create_book_copies()
BEGIN
  DECLARE done INT DEFAULT FALSE;
  DECLARE b_id INT;
  DECLARE tc INT;
  DECLARE cur1 CURSOR FOR SELECT BookID, COALESCE(TotalCopies,1) FROM books;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
  OPEN cur1;
  read_loop: LOOP
    FETCH cur1 INTO b_id, tc;
    IF done THEN LEAVE read_loop; END IF;
    IF tc IS NULL THEN SET tc = 1; END IF;
    -- create copies until count reaches TotalCopies
    WHILE (SELECT COUNT(*) FROM book_copies WHERE BookID = b_id) < tc DO
      INSERT INTO book_copies (BookID, Barcode) VALUES (b_id, CONCAT('BC-', b_id, '-', UUID()));
    END WHILE;
  END LOOP;
  CLOSE cur1;
END$$

DROP PROCEDURE IF EXISTS reserve_book$$
CREATE PROCEDURE reserve_book(IN p_student INT, IN p_book INT)
BEGIN
  DECLARE c_id INT;
  SELECT CopyID INTO c_id FROM book_copies WHERE BookID = p_book AND Status='available' LIMIT 1 FOR UPDATE;
  IF c_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No available copy to reserve';
  ELSE
    UPDATE book_copies SET Status='reserved' WHERE CopyID = c_id;
    INSERT INTO reservations (StudentID, BookID, CopyID, ExpiresAt) VALUES (p_student, p_book, c_id, DATE_ADD(NOW(), INTERVAL 2 DAY));
    INSERT INTO audit_logs (ActorUserID, ActionType, ActionDetails) VALUES (p_student, 'reserve', CONCAT('Reserved CopyID=', c_id, ' BookID=', p_book));
  END IF;
END$$

DROP PROCEDURE IF EXISTS request_extension$$
CREATE PROCEDURE request_extension(IN p_record INT, IN p_new_due DATE)
BEGIN
  INSERT INTO extensions (RecordID, NewDueDate, Status) VALUES (p_record, p_new_due, 'pending');
  INSERT INTO audit_logs (ActorUserID, ActionType, ActionDetails) VALUES (NULL, 'request_extension', CONCAT('RecordID=', p_record, ' NewDue=', p_new_due));
END$$
DELIMITER ;

-- trigger for auditing borrow updates
DELIMITER $$
DROP TRIGGER IF EXISTS trg_after_borrow_update$$
CREATE TRIGGER trg_after_borrow_update
AFTER UPDATE ON borrow_records
FOR EACH ROW
BEGIN
  IF OLD.Returned = 0 AND NEW.Returned = 1 THEN
    INSERT INTO audit_logs (ActorUserID, ActionType, ActionDetails) VALUES (NEW.ReturnedBy, 'return', CONCAT('RecordID=', NEW.RecordID, ' Fine=', NEW.Fine));
  ELSEIF OLD.Returned = 0 AND NEW.Returned = 0 AND OLD.IssueDate IS NULL AND NEW.IssueDate IS NOT NULL THEN
    INSERT INTO audit_logs (ActorUserID, ActionType, ActionDetails) VALUES (NEW.IssuedBy, 'issue', CONCAT('RecordID=', NEW.RecordID));
  END IF;
END$$
DELIMITER ;

-- sample data: 25 books
INSERT INTO books (ISBN, Title, Author, Publisher, Year, Category, TotalCopies, AvailableCopies, Description, ISBN13) VALUES
('9780140449136','The Odyssey','Homer','Penguin',1996,'Epic',3,3,'Epic poem.','9780140449136'),
('9780140449181','Iliad','Homer','Penguin',1998,'Epic',3,3,'Epic of Troy.','9780140449181'),
('9780747532743','Harry Potter and the Philosopher''s Stone','J.K. Rowling','Bloomsbury',1997,'Fiction',5,5,'First in HP series.','9780747532743'),
('9780590353427','Harry Potter and the Chamber of Secrets','J.K. Rowling','Bloomsbury',1998,'Fiction',4,4,'Second in HP series.','9780590353427'),
('9780307277671','The Road','Cormac McCarthy','Vintage',2006,'Fiction',2,2,'Post-apocalyptic novel.','9780307277671'),
('9780141439518','Pride and Prejudice','Jane Austen','Penguin',1813,'Fiction',3,3,'Classic romance.','9780141439518'),
('9780061120084','To Kill a Mockingbird','Harper Lee','Harper',1960,'Fiction',3,3,'Novel about injustice.','9780061120084'),
('9780131103627','The C Programming Language','Kernighan & Ritchie','Prentice Hall',1988,'Programming',2,2,'C language classic.','9780131103627'),
('9780131101630','The UNIX Programming Environment','Kernighan & Pike','Prentice Hall',1984,'Programming',2,2,'UNIX programming.','9780131101630'),
('9780134092669','Modern Operating Systems','Andrew S. Tanenbaum','Pearson',2014,'Operating Systems',3,3,'OS concepts.','9780134092669'),
('9780137903955','Operating System Concepts','Silberschatz','Wiley',2018,'Operating Systems',2,2,'OS fundamentals.','9780137903955'),
('9781491957660','Fluent Python','Luciano Ramalho','O''Reilly Media',2015,'Programming',2,2,'Python best practices.','9781491957660'),
('9780132356138','Clean Code','Robert C. Martin','Prentice Hall',2008,'Programming',3,3,'Software craftsmanship.','9780132356138'),
('9780201633610','Design Patterns','Gamma et al.','Addison-Wesley',1994,'Computer Science',2,2,'OO design patterns.','9780201633610'),
('9780262033848','Introduction to Algorithms','Thomas H. Cormen','MIT Press',2009,'Computer Science',2,2,'Algorithms textbook.','9780262033848'),
('9780261103573','The Lord of the Rings','J.R.R. Tolkien','Allen & Unwin',1954,'Fiction',3,3,'Epic fantasy.','9780261103573'),
('9780307269997','The Lean Startup','Eric Ries','Crown',2011,'Non-Fiction',2,2,'Startup methodology.','9780307269997'),
('9780143127550','Thinking, Fast and Slow','Daniel Kahneman','Farrar',2011,'Non-Fiction',2,2,'Decision making.','9780143127550'),
('9780134685991','Effective Java','Joshua Bloch','Addison-Wesley',2018,'Programming',2,2,'Java best practices.','9780134685991'),
('9781491978961','Python Cookbook','David Beazley','O''Reilly Media',2013,'Programming',2,2,'Python recipes.','9781491978961'),
('9780596007126','Head First Design Patterns','Eric Freeman','O''Reilly Media',2004,'Computer Science',2,2,'Design patterns learning.','9780596007126'),
('9780201485677','Refactoring','Martin Fowler','Addison-Wesley',1999,'Programming',2,2,'Improve existing code.','9780201485677'),
('9780131103627-2','C Programming: Exercises','Kernighan','Prentice Hall',1990,'Programming',1,1,'Exercises for C.','9780131103627-2'),
('9780262035613','Introduction to Machine Learning','Ethem Alpaydin','MIT Press',2014,'Computer Science',2,2,'ML concepts.','9780262035613');

-- 5 students
INSERT INTO students (RollNo, Name, Department, Email, Phone) VALUES
('1PE21CS101','Akash Gupta','CSE','akash.gupta@example.com','9876010001'),
('1PE21EC102','Meera Sharma','ECE','meera.sharma@example.com','9876010002'),
('1PE21IS103','Priya Singh','ISE','priya.singh2@example.com','9876010003'),
('1PE21ME104','Rohit Kumar','ME','rohit.kumar@example.com','9876010004'),
('1PE21CE105','Neha Reddy','CE','neha.reddy@example.com','9876010005');

-- 3 librarians (staff)
INSERT INTO staff (Name, Role, Email, Phone) VALUES
('Lib_Admin1','Librarian','libadmin1@pes.edu','0801111001'),
('Lib_Admin2','Librarian','libadmin2@pes.edu','0801111002'),
('Lib_Admin3','Librarian','libadmin3@pes.edu','0801111003');

-- users (5 students + 3 librarians)
INSERT INTO users (Username, Password, Role, LinkedID) VALUES
('akash','akashpass','student', (SELECT StudentID FROM students WHERE RollNo='1PE21CS101')),
('meera','meerpass','student', (SELECT StudentID FROM students WHERE RollNo='1PE21EC102')),
('priya2','priyapass','student', (SELECT StudentID FROM students WHERE RollNo='1PE21IS103')),
('rohit','rohitpass','student', (SELECT StudentID FROM students WHERE RollNo='1PE21ME104')),
('neha','nehapass','student', (SELECT StudentID FROM students WHERE RollNo='1PE21CE105')),
('lib1','libpass','librarian', (SELECT StaffID FROM staff WHERE Name='Lib_Admin1')),
('lib2','libpass2','librarian', (SELECT StaffID FROM staff WHERE Name='Lib_Admin2')),
('lib3','libpass3','librarian', (SELECT StaffID FROM staff WHERE Name='Lib_Admin3'));

-- create copies for all books (procedure exists above)
CALL create_book_copies();

-- sample reviews & reservation (optional demo)
INSERT INTO reviews (BookID, StudentID, Rating, Comment) VALUES
((SELECT BookID FROM books WHERE Title LIKE 'Harry Potter and the Philosopher%' LIMIT 1), (SELECT StudentID FROM students WHERE RollNo='1PE21CS101' LIMIT 1), 5, 'Magical!'),
((SELECT BookID FROM books WHERE Title='Introduction to Algorithms' LIMIT 1), (SELECT StudentID FROM students WHERE RollNo='1PE21IS103' LIMIT 1), 4, 'Great textbook.');

INSERT INTO reservations (StudentID, BookID, CopyID, ExpiresAt) VALUES
((SELECT StudentID FROM students WHERE RollNo='1PE21CS101' LIMIT 1),
 (SELECT BookID FROM books WHERE Title='The C Programming Language' LIMIT 1),
 (SELECT CopyID FROM book_copies WHERE BookID=(SELECT BookID FROM books WHERE Title='The C Programming Language' LIMIT 1) LIMIT 1),
 DATE_ADD(NOW(), INTERVAL 2 DAY));
