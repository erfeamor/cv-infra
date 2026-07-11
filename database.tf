resource "aws_db_subnet_group" "cv" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = data.aws_subnets.default.ids

  tags = {
    Project = var.project_name
  }
}

resource "aws_db_instance" "cv" {
  identifier     = "${var.project_name}-${var.environment}"
  engine         = "mysql"
  engine_version = "8.0"

  # Free Tier: db.t3.micro / db.t2.micro, up to 20GB gp2 storage, single-AZ.
  instance_class      = "db.t3.micro"
  allocated_storage   = 20
  storage_type        = "gp2"
  multi_az            = false
  publicly_accessible = false

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.cv.name
  vpc_security_group_ids = [aws_security_group.database.id]

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = {
    Project = var.project_name
  }
}
