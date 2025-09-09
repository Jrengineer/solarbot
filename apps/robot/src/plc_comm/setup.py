from setuptools import setup

package_name = 'plc_comm'

setup(
    name=package_name,
    version='0.0.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    install_requires=['setuptools', 'pymodbus'],
    zip_safe=True,
    maintainer='kaanjetson',
    maintainer_email='kaanjetson@example.com',
    description='Delta PLC ile ROS 2 üzerinden haberleşme',
    license='MIT',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            'plc_comm_node = plc_comm.udp_listener_node:main',
            'plc_write_node = plc_comm.plc_write_node:main',
            'plc_write_read_node = plc_comm.plc_write_read_node:main',
            'plc_write_m11_node = plc_comm.plc_write_m11:main',
            'udp_listener_node = plc_comm.udp_listener_node:main',
                  # 🆕 BU SATIR EKLENDİ
        ],
    },
)
