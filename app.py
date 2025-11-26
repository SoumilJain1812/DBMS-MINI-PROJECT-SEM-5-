from flask import Flask, render_template, request, redirect, url_for, session, flash
import mysql.connector
from functools import wraps

app = Flask(__name__)
app.secret_key = 'replace-with-secure-key'

def get_db():
    return mysql.connector.connect(host='localhost', user='root', password='qwerty@1', database='library_db')

def login_required(role=None):
    def decorator(f):
        @wraps(f)
        def wrapped(*args, **kwargs):
            if 'user' not in session:
                return redirect(url_for('login'))
            if role and session.get('role') != role:
                flash('Access denied', 'danger'); return redirect(url_for('index'))
            return f(*args, **kwargs)
        return wrapped
    return decorator

@app.route('/')
def index():
    return render_template('index.html', user=session.get('user'))

@app.route('/login', methods=['GET','POST'])
def login():
    if request.method=='POST':
        username=request.form['username']; password=request.form['password']
        conn=get_db(); cur=conn.cursor(dictionary=True)
        cur.execute("SELECT * FROM users WHERE Username=%s",(username,))
        user=cur.fetchone(); cur.close(); conn.close()
        if user and user['Password']==password:
            session['user']=user['Username']; session['role']=user['Role']; session['userid']=user['UserID']
            flash('Logged in','success'); return redirect(url_for('dashboard'))
        flash('Invalid credentials','danger')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.clear(); flash('Logged out','info'); return redirect(url_for('index'))

@app.route('/dashboard')
@login_required()
def dashboard():
    conn=get_db(); cur=conn.cursor(dictionary=True)
    cur.execute("SELECT COUNT(*) AS total_books FROM books"); total_books=cur.fetchone()['total_books']
    cur.execute("SELECT COUNT(*) AS borrowed FROM borrow_records WHERE Returned=FALSE"); borrowed=cur.fetchone()['borrowed']
    cur.execute("SELECT COUNT(*) AS overdue FROM borrow_records WHERE Returned=FALSE AND DueDate < CURDATE()"); overdue=cur.fetchone()['overdue']
    cur.close(); conn.close()
    return render_template('dashboard.html', total_books=total_books, borrowed=borrowed, overdue=overdue)

@app.route('/books')
@login_required()
def books():
    conn=get_db(); cur=conn.cursor(dictionary=True)
    cur.execute("SELECT * FROM books ORDER BY Title LIMIT 100")
    rows=cur.fetchall(); cur.close(); conn.close()
    return render_template('books.html', books=rows)

@app.route('/books/add', methods=['GET','POST'])
@login_required(role='librarian')
def add_book():
    if request.method=='POST':
        title=request.form['title']; author=request.form['author']; isbn=request.form['isbn']; total=int(request.form.get('total',1))
        conn=get_db(); cur=conn.cursor()
        cur.execute("INSERT INTO books (ISBN, Title, Author, TotalCopies, AvailableCopies) VALUES (%s,%s,%s,%s,%s)",
                    (isbn, title, author, total, total))
        conn.commit(); cur.close(); conn.close(); flash('Book added','success'); return redirect(url_for('books'))
    return render_template('add_book.html')

@app.route('/books/delete/<int:bookid>', methods=['POST'])
@login_required(role='librarian')
def delete_book(bookid):
    conn=get_db(); cur=conn.cursor(); cur.execute("DELETE FROM books WHERE BookID=%s",(bookid,)); conn.commit(); cur.close(); conn.close(); flash('Deleted','info'); return redirect(url_for('books'))

@app.route('/issue', methods=['GET','POST'])
@login_required()
def issue():
    if request.method=='POST':
        student_id=int(request.form['student_id']); book_id=int(request.form['book_id']); issued_by=1
        conn=get_db(); cur=conn.cursor()
        try:
            cur.callproc('issue_book', (student_id, book_id, issued_by)); conn.commit(); flash('Issued','success')
        except mysql.connector.Error as err:
            flash(str(err), 'danger')
        finally:
            cur.close(); conn.close()
        return redirect(url_for('books'))
    conn=get_db(); cur=conn.cursor(dictionary=True)
    cur.execute("SELECT StudentID, Name FROM students"); students=cur.fetchall()
    cur.execute("SELECT BookID, Title, AvailableCopies FROM books WHERE AvailableCopies>0"); books=cur.fetchall()
    cur.close(); conn.close(); return render_template('issue.html', students=students, books=books)

@app.route('/return', methods=['GET','POST'])
@login_required()
def return_book():
    if request.method=='POST':
        record_id=int(request.form['record_id']); returned_by=1
        conn=get_db(); cur=conn.cursor()
        try:
            cur.callproc('return_book', (record_id, returned_by)); conn.commit(); flash('Returned','success')
        except mysql.connector.Error as err:
            flash(str(err), 'danger')
        finally:
            cur.close(); conn.close()
        return redirect(url_for('dashboard'))
    conn=get_db(); cur=conn.cursor(dictionary=True)
    cur.execute("SELECT br.RecordID, s.Name AS StudentName, b.Title, br.IssueDate, br.DueDate FROM borrow_records br JOIN students s ON br.StudentID=s.StudentID JOIN books b ON br.BookID=b.BookID WHERE br.Returned=FALSE")
    records=cur.fetchall(); cur.close(); conn.close(); return render_template('return.html', records=records)

@app.route('/reports')
@login_required(role='librarian')
def reports():
    conn=get_db(); cur=conn.cursor(dictionary=True)
    cur.execute("SELECT Category, COUNT(*) AS cnt FROM books GROUP BY Category")
    agg=cur.fetchall()
    cur.execute("SELECT br.RecordID, s.Name, b.Title, br.IssueDate, br.DueDate, br.ReturnDate, br.Fine FROM borrow_records br JOIN students s ON br.StudentID=s.StudentID JOIN books b ON br.BookID=b.BookID ORDER BY br.CreatedAt DESC LIMIT 10")
    join_rows=cur.fetchall()
    cur.execute("SELECT Name FROM students WHERE StudentID IN (SELECT StudentID FROM borrow_records WHERE Returned=FALSE AND DueDate < CURDATE())")
    nested=cur.fetchall(); cur.close(); conn.close(); return render_template('reports.html', agg=agg, join_rows=join_rows, nested=nested)

if __name__=='__main__':
    app.run(debug=True)
